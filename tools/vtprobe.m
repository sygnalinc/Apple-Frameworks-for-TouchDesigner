// VideoToolbox VTFrameProcessor の対応状況を実機で調べる
//   clang -fobjc-arc -framework Foundation -framework VideoToolbox -o /tmp/vtprobe tools/vtprobe.m && /tmp/vtprobe
// Apple は対応チップ一覧を公開していないので、動かすマシンで isSupported を見るしかない。
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <sys/sysctl.h>

static NSString* sysstr(const char* k) {
    size_t n = 0; if (sysctlbyname(k, NULL, &n, NULL, 0) || !n) return @"?";
    char* b = malloc(n); sysctlbyname(k, b, &n, NULL, 0);
    NSString* s = [NSString stringWithUTF8String:b]; free(b); return s;
}
static void row(NSString* name, BOOL sup, Class cls) {
    printf("%-34s %-4s", name.UTF8String, sup ? "YES" : "no");
    if (cls && [cls respondsToSelector:@selector(minimumDimensions)]) {
        CMVideoDimensions mn = [cls minimumDimensions], mx = [cls maximumDimensions];
        printf("  %dx%d .. %dx%d", mn.width, mn.height, mx.width, mx.height);
    }
    printf("\n");
}
int main(void) { @autoreleasepool {
    printf("machine : %s / %s\n", sysstr("hw.model").UTF8String, sysstr("machdep.cpu.brand_string").UTF8String);
    printf("os      : %s\n\n", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
    printf("%-34s %-4s  %s\n", "processor", "sup", "min .. max dimensions");
    printf("%-34s %-4s  %s\n", "---------", "---", "---------------------");
    if (@available(macOS 15.4, *)) {
        row(@"OpticalFlow", VTOpticalFlowConfiguration.isSupported, VTOpticalFlowConfiguration.class);
        row(@"MotionBlur", VTMotionBlurConfiguration.isSupported, VTMotionBlurConfiguration.class);
        row(@"FrameRateConversion", VTFrameRateConversionConfiguration.isSupported, VTFrameRateConversionConfiguration.class);
        row(@"SuperResolutionScaler", VTSuperResolutionScalerConfiguration.isSupported, VTSuperResolutionScalerConfiguration.class);
    }
    if (@available(macOS 26.0, *)) {
        row(@"TemporalNoiseFilter", VTTemporalNoiseFilterConfiguration.isSupported, VTTemporalNoiseFilterConfiguration.class);
        row(@"LowLatencySuperResolutionScaler", VTLowLatencySuperResolutionScalerConfiguration.isSupported, VTLowLatencySuperResolutionScalerConfiguration.class);
        row(@"LowLatencyFrameInterpolation", VTLowLatencyFrameInterpolationConfiguration.isSupported, VTLowLatencyFrameInterpolationConfiguration.class);
    }
    return 0;
}}
