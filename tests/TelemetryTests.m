#import <Foundation/Foundation.h>

#define main TeamsMuteHelperApplicationMain
#include "../TeamsMuteHelper.m"
#undef main

@interface TeamsMuteHelperDelegate (TelemetryTests)
- (void)clearPendingTelemetryCounts;
- (void)incrementTelemetryAggregateType:(NSString *)type payload:(NSDictionary *)payload;
- (NSDictionary *)telemetrySignalWithType:(NSString *)type
                                   payload:(NSDictionary *)payload
                                     count:(NSNumber *)count;
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "Telemetry test failed: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Require([ToggleInvocationSourceName(ToggleInvocationSourceHotKey) isEqualToString:@"hotkey"],
                @"hotkey source name");
        Require([UpdateCheckSourceName(UpdateCheckSourceAutomatic) isEqualToString:@"automatic"],
                @"automatic update source name");

        ToggleRunResult verified = MakeToggleRunResult(0, DeliveryModeAX, YES);
        Require([ToggleFailureReason(verified) isEqualToString:@"none"],
                @"verified result reason");
        Require([DeliveryModeName(verified.successfulDeliveryMode) isEqualToString:@"ax"],
                @"verified result delivery mode");

        ToggleRunResult unverified = MakeToggleRunResult(0, DeliveryModePID, NO);
        unverified.unverified = YES;
        Require([ToggleFailureReason(unverified) isEqualToString:@"mic_state_unavailable"],
                @"unverified result reason");

        ToggleRunResult busy = MakeToggleRunResult(7, DeliveryModeNone, NO);
        Require([ToggleFailureReason(busy) isEqualToString:@"another_instance_running"],
                @"busy result reason");

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:YES forKey:kTelemetryConsentPresentedPreference];
        [defaults setBool:YES forKey:kShareAnonymousUsageDataPreference];

        TeamsMuteHelperDelegate *delegate = [[TeamsMuteHelperDelegate alloc] init];
        [delegate clearPendingTelemetryCounts];
        NSDictionary *payload = @{
            @"Helper.invocationSource": @"hotkey",
            @"Helper.outcome": @"verified",
        };
        [delegate incrementTelemetryAggregateType:@"Usage.Toggle.completed" payload:payload];
        [delegate incrementTelemetryAggregateType:@"Usage.Toggle.completed" payload:payload];
        [delegate incrementTelemetryAggregateType:@"Update.Check.completed"
                                          payload:@{@"Update.result": @"up_to_date"}];

        NSDictionary<NSString *, NSNumber *> *counts =
            [defaults dictionaryForKey:kTelemetryAggregateCountsPreference];
        Require(counts.count == 2, @"matching aggregates coalesce");
        NSInteger total = 0;
        for (NSNumber *count in counts.allValues) {
            total += count.integerValue;
        }
        Require(total == 3, @"aggregate counts are preserved");

        NSDictionary *signal = [delegate telemetrySignalWithType:@"Usage.Toggle.completed"
                                                          payload:payload
                                                            count:@2];
        NSDictionary *signalPayload = signal[@"payload"];
        Require([signal[@"floatValue"] isEqual:@2], @"aggregate uses floatValue");
        Require([signal[@"isTestMode"] isEqual:@YES], @"source build uses test mode");
        Require([signalPayload[@"TelemetryDeck.Device.platform"] isEqualToString:@"macOS"],
                @"canonical platform metadata");
        Require([signalPayload[@"Helper.distributionChannel"] isEqualToString:@"source"],
                @"source distribution channel");

        [delegate clearPendingTelemetryCounts];
        [defaults removeObjectForKey:kTelemetryConsentPresentedPreference];
        [defaults removeObjectForKey:kShareAnonymousUsageDataPreference];
        [defaults removeObjectForKey:kTelemetryInstallationIDPreference];
        [defaults synchronize];
    }
    printf("Telemetry tests passed\n");
    return 0;
}
