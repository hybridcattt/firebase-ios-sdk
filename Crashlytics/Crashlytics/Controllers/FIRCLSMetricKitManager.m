// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <Foundation/Foundation.h>

#import "Crashlytics/Crashlytics/Controllers/FIRCLSMetricKitManager.h"

#if CLS_METRICKIT_SUPPORTED

#import "Crashlytics/Crashlytics/Controllers/FIRCLSManagerData.h"
#import "Crashlytics/Crashlytics/Helpers/FIRCLSFile.h"
#import "Crashlytics/Crashlytics/Helpers/FIRCLSLogger.h"
#import "Crashlytics/Crashlytics/Models/FIRCLSExecutionIdentifierModel.h"
#import "Crashlytics/Crashlytics/Models/FIRCLSInternalReport.h"
#import "Crashlytics/Crashlytics/Public/FirebaseCrashlytics/FIRCrashlyticsReport.h"

@interface FIRCLSMetricKitManager ()

@property FBLPromise *metricKitDataAvailable;
@property FIRCLSExistingReportManager *existingReportManager;
@property FIRCLSFileManager *fileManager;
@property FIRCLSManagerData *managerData;

@end

@implementation FIRCLSMetricKitManager

- (instancetype)initWithManagerData:(FIRCLSManagerData *)managerData
              existingReportManager:(FIRCLSExistingReportManager *)existingReportManager
                        fileManager:(FIRCLSFileManager *)fileManager {
  _existingReportManager = existingReportManager;
  _fileManager = fileManager;
  _managerData = managerData;
  return self;
}

/*
 * Registers the MetricKit manager to receive MetricKit reports by adding self to the
 * MXMetricManager subscribers. Also initializes the promise that we'll use to ensure that any
 * MetricKit report files are included in Crashylytics fatal reports. If no crash occurred on the
 * last run of the app, this promise is immediately resolved so that the upload of any nonfatal
 * events can proceed.
 */
- (void)registerMetricKitManager {
  [[MXMetricManager sharedManager] addSubscriber:self];
  self.metricKitDataAvailable = [FBLPromise pendingPromise];

  // If there was no crash on the last run of the app, then we aren't expecting a MetricKit
  // diagnostic report and should resolve the promise immediately. If MetricKit captured a fatal
  // event and Crashlytics did not, then we'll still process the MetricKit crash but won't upload
  // it until the app restarts again.
  if (![self.fileManager didCrashOnPreviousExecution]) {
    @synchronized(self) {
      [self.metricKitDataAvailable fulfill:nil];
    }
  }
}

/*
 * This method receives diagnostic payloads from MetricKit whenever a fatal or nonfatal MetricKit
 * event occurs. If a fatal event, this method will be called when the app restarts. Since we're
 * including a MetricKit report file in the Crashlytics report to be sent to the backend, we need
 * to make sure that we process the payloads and write the included information to file before
 * the report is sent up. If this method is called due to a nonfatal event, it will be called
 * immediately after the event. Since we send nonfatal events on the next run of the app, we can
 * write out the information but won't need to resolve the promise.
 */
- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
  for (MXDiagnosticPayload *diagnosticPayload in payloads) {
    if (!diagnosticPayload) {
      continue;
    }

    BOOL processedPayload = [self processMetricKitPayload:diagnosticPayload];
    BOOL fatal = processedPayload && ([diagnosticPayload.crashDiagnostics count] > 0);
    if (fatal) {
      // Since we only want to handle one crash per report, if this was a fatal event
      // don't process any additional payloads.
      break;
    }
  }
  // Once we've processed all the payloads, resolve the promise so that reporting uploading
  // continues. If there was not a crash on the previous run of the app, the promise wil already
  // have been resolved.
  @synchronized(self) {
    [self.metricKitDataAvailable fulfill:nil];
  }
}

// Helper method to write a MetricKit payload's data to file.
- (BOOL)processMetricKitPayload:(MXDiagnosticPayload *)diagnosticPayload {
  // TODO: Time stamp information is only available in begin and end time periods. Hopefully this
  // is updated with iOS 15.
  NSTimeInterval beginSecondsSince1970 = [diagnosticPayload.timeStampBegin timeIntervalSince1970];
  NSTimeInterval endSecondsSince1970 = [diagnosticPayload.timeStampEnd timeIntervalSince1970];

  // Get file path for the active reports directory.
  NSString *activePath = [[self.fileManager activePath] stringByAppendingString:@"/"];

  // If there is a crash diagnostic in the payload, then this method was called for a fatal event.
  // Also ensure that there is a report from the last run of the app that we can write to.
  NSString *metricKitReportFile;
  NSString *newestUnsentReportID =
      [self.existingReportManager.newestUnsentReport.reportID stringByAppendingString:@"/"];
  BOOL fatal = ([diagnosticPayload.crashDiagnostics count] > 0) && (newestUnsentReportID != nil) &&
               ([self.fileManager
                   fileExistsAtPath:[activePath stringByAppendingString:newestUnsentReportID]]);

  // Set the metrickit path appropriately depending on whether the diagnostic report came from
  // a fatal or nonfatal event. If fatal, use the report from the last run of the app. Otherwise,
  // use the report for the current run.
  if (fatal) {
    metricKitReportFile = [[activePath stringByAppendingString:newestUnsentReportID]
        stringByAppendingString:FIRCLSMetricKitReportFile];
  } else {
    NSString *currentReportID =
        [_managerData.executionIDModel.executionID stringByAppendingString:@"/"];
    metricKitReportFile = [[activePath stringByAppendingString:currentReportID]
        stringByAppendingString:FIRCLSMetricKitReportFile];
  }

  if (!metricKitReportFile) {
    FIRCLSDebugLog(@"[Crashlytics:Crash] error finding MetricKit file");
    return NO;
  }

  FIRCLSDebugLog(@"[Crashlytics:Crash] file path for MetricKit:  %@", [metricKitReportFile copy]);
  FIRCLSFile metricKitFile;
  if (!FIRCLSFileInitWithPath(&metricKitFile, [metricKitReportFile UTF8String], false)) {
    FIRCLSDebugLog(@"[Crashlytics:Crash] unable to open MetricKit file");
    return NO;
  }

  // Write out time information to the MetricKit report file. Time needs to be a value for
  // backend serialization, so we'll write out two sections to capture all the information.
  FIRCLSFileWriteHashStart(&metricKitFile);
  FIRCLSFileWriteHashEntryUint64(&metricKitFile, "time", beginSecondsSince1970);
  FIRCLSFileWriteSectionEnd(&metricKitFile);

  FIRCLSFileWriteSectionStart(&metricKitFile, "time_details");
  FIRCLSFileWriteHashStart(&metricKitFile);
  FIRCLSFileWriteHashEntryUint64(&metricKitFile, "begin_time", beginSecondsSince1970);
  FIRCLSFileWriteHashEntryUint64(&metricKitFile, "end_time", endSecondsSince1970);
  FIRCLSFileWriteHashEnd(&metricKitFile);
  FIRCLSFileWriteSectionEnd(&metricKitFile);

  // Write out each type of diagnostic if it exists in the report
  BOOL hasCrash = [diagnosticPayload.crashDiagnostics count] > 0;
  BOOL hasHang = [diagnosticPayload.hangDiagnostics count] > 0;
  BOOL hasCPUException = [diagnosticPayload.cpuExceptionDiagnostics count] > 0;
  BOOL hasDiskWriteException = [diagnosticPayload.diskWriteExceptionDiagnostics count] > 0;

  // For each diagnostic type, write out a section in the MetricKit report file. This section will
  // have subsections for threads, metadata, and event specific metadata.
  if (hasCrash) {
    FIRCLSFileWriteSectionStart(&metricKitFile, "crash_event");
    MXCrashDiagnostic *crashDiagnostic = [diagnosticPayload.crashDiagnostics objectAtIndex:0];

    NSData *threads = [crashDiagnostic.callStackTree JSONRepresentation];
    NSData *metadata = [crashDiagnostic.metaData JSONRepresentation];
    [self writeThreadsToFile:&metricKitFile threads:threads];
    [self writeMetadataToFile:&metricKitFile metadata:metadata];

    NSString *nilString = @"";
    NSDictionary *crashDict = @{
      @"termination_reason" :
              (crashDiagnostic.terminationReason) ? crashDiagnostic.terminationReason : nilString,
      @"virtual_memory_region_info" : (crashDiagnostic.virtualMemoryRegionInfo)
          ? crashDiagnostic.virtualMemoryRegionInfo
          : nilString,
      @"exception_type" : crashDiagnostic.exceptionType,
      @"exception_code" : crashDiagnostic.exceptionCode,
      @"signal" : crashDiagnostic.signal
    };
    [self writeEventSpecificDataToFile:&metricKitFile event:@"crash" data:crashDict];
    FIRCLSFileWriteHashEnd(&metricKitFile);
    FIRCLSFileWriteSectionEnd(&metricKitFile);
  }

  if (hasHang) {
    FIRCLSFileWriteSectionStart(&metricKitFile, "hang_event");
    MXHangDiagnostic *hangDiagnostic = [diagnosticPayload.hangDiagnostics objectAtIndex:0];

    NSData *threads = [hangDiagnostic.callStackTree JSONRepresentation];
    NSData *metadata = [hangDiagnostic.metaData JSONRepresentation];
    [self writeThreadsToFile:&metricKitFile threads:threads];
    [self writeMetadataToFile:&metricKitFile metadata:metadata];

    NSDictionary *hangDict = @{@"hang_duration" : hangDiagnostic.hangDuration};
    [self writeEventSpecificDataToFile:&metricKitFile event:@"hang" data:hangDict];
    FIRCLSFileWriteHashEnd(&metricKitFile);
    FIRCLSFileWriteSectionEnd(&metricKitFile);
  }

  if (hasCPUException) {
    FIRCLSFileWriteSectionStart(&metricKitFile, "cpu_exception_event");
    MXCPUExceptionDiagnostic *cpuExceptionDiagnostic =
        [diagnosticPayload.cpuExceptionDiagnostics objectAtIndex:0];

    NSData *threads = [cpuExceptionDiagnostic.callStackTree JSONRepresentation];
    NSData *metadata = [cpuExceptionDiagnostic.metaData JSONRepresentation];
    [self writeThreadsToFile:&metricKitFile threads:threads];
    [self writeMetadataToFile:&metricKitFile metadata:metadata];

    NSDictionary *cpuDict = @{
      @"total_cpu_time" : cpuExceptionDiagnostic.totalCPUTime,
      @"total_sampled_time" : cpuExceptionDiagnostic.totalSampledTime
    };
    [self writeEventSpecificDataToFile:&metricKitFile event:@"cpu_exception" data:cpuDict];
    FIRCLSFileWriteHashEnd(&metricKitFile);
    FIRCLSFileWriteSectionEnd(&metricKitFile);
  }

  if (hasDiskWriteException) {
    FIRCLSFileWriteSectionStart(&metricKitFile, "disk_write_exception_event");
    MXDiskWriteExceptionDiagnostic *diskWriteExceptionDiagnostic =
        [diagnosticPayload.diskWriteExceptionDiagnostics objectAtIndex:0];

    NSData *threads = [diskWriteExceptionDiagnostic.callStackTree JSONRepresentation];
    NSData *metadata = [diskWriteExceptionDiagnostic.metaData JSONRepresentation];
    [self writeThreadsToFile:&metricKitFile threads:threads];
    [self writeMetadataToFile:&metricKitFile metadata:metadata];

    NSDictionary *diskDict =
        @{@"total_writes_caused" : diskWriteExceptionDiagnostic.totalWritesCaused};
    [self writeEventSpecificDataToFile:&metricKitFile event:@"disk_write_exception" data:diskDict];
    FIRCLSFileWriteHashEnd(&metricKitFile);
    FIRCLSFileWriteSectionEnd(&metricKitFile);
  }

  return YES;
}
/*
 * Required for MXMetricManager subscribers. Since we aren't currently collecting any MetricKit
 * metrics, this method is left empty.
 */
- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
  FIRCLSDebugLog(@"[Crashlytics:Crash] received %d MetricKit metric payloads\n", payloads.count);
}

- (FBLPromise *)waitForMetricKitDataAvailable {
  FBLPromise *result = nil;
  @synchronized(self) {
    result = self.metricKitDataAvailable;
  }
  return result;
}

/*
 * Helper method to write threads for a MetricKit diagnostic event to file.
 */
- (void)writeThreadsToFile:(FIRCLSFile *)metricKitFile threads:(NSData *)threads {
  //  FIRCLSFileWriteSectionStart(metricKitFile, "threads");
  FIRCLSFileWriteStringUnquoted(metricKitFile, "{\"threads\":");
  NSMutableString *threadsString = [[NSMutableString alloc] initWithData:threads
                                                                encoding:NSUTF8StringEncoding];
  [threadsString replaceOccurrencesOfString:@"\n"
                                 withString:@""
                                    options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(0, [threadsString length])];
  [threadsString replaceOccurrencesOfString:@"        "
                                 withString:@""
                                    options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(0, [threadsString length])];
  metricKitFile->needComma = YES;
  FIRCLSFileWriteStringUnquoted(metricKitFile, [threadsString UTF8String]);

  //  FIRCLSFileWriteHashEnd(metricKitFile);
}

/*
 * Helper method to write metadata for a MetricKit diagnostic event to file.
 */
- (void)writeMetadataToFile:(FIRCLSFile *)metricKitFile metadata:(NSData *)metadata {
  //  FIRCLSFileWriteSectionStart(metricKitFile, "metadata");
  FIRCLSFileWriteStringUnquoted(metricKitFile, ",\"metadata\":");
  NSMutableString *metadataString = [[NSMutableString alloc] initWithData:metadata
                                                                 encoding:NSUTF8StringEncoding];
  [metadataString replaceOccurrencesOfString:@"\n"
                                  withString:@""
                                     options:NSCaseInsensitiveSearch
                                       range:NSMakeRange(0, [metadataString length])];
  [metadataString replaceOccurrencesOfString:@"        "
                                  withString:@""
                                     options:NSCaseInsensitiveSearch
                                       range:NSMakeRange(0, [metadataString length])];
  metricKitFile->needComma = YES;
  FIRCLSFileWriteStringUnquoted(metricKitFile, [metadataString UTF8String]);
  //  FIRCLSFileWriteHashEnd(metricKitFile);
}

/*
 * Helper method to write event-specific metadata for a MetricKit diagnostic event to file.
 */
- (void)writeEventSpecificDataToFile:(FIRCLSFile *)metricKitFile
                               event:(NSString *)event
                                data:(NSDictionary *)data {
  for (NSString *key in data) {
    id value = [data objectForKey:key];
    if ([value isKindOfClass:[NSString class]]) {
      const char *stringValue = [(NSString *)value UTF8String];
      FIRCLSFileWriteHashEntryString(metricKitFile, [key UTF8String], stringValue);
    } else if ([value isKindOfClass:[NSNumber class]]) {
      FIRCLSFileWriteHashEntryUint64(metricKitFile, [key UTF8String],
                                     [[data objectForKey:key] integerValue]);
    }
  };
}

@end

#endif  // CLS_METRICKIT_SUPPORTED
