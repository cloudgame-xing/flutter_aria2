#import "FlutterAria2Plugin.h"

#import "FlutterAria2Native.h"

@interface FlutterAria2Plugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, strong) FlutterAria2Native* native;
@end

@implementation FlutterAria2Plugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"flutter_aria2"
                                  binaryMessenger:[registrar messenger]];
  FlutterAria2Plugin* instance = [[FlutterAria2Plugin alloc] initWithChannel:channel];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithChannel:(FlutterMethodChannel*)channel {
  self = [super init];
  if (self) {
    _channel = channel;
    _native = [[FlutterAria2Native alloc] init];
    __weak typeof(self) weakSelf = self;
    _native.onDownloadEvent = ^(NSInteger event, NSString* gid) {
      [weakSelf.channel invokeMethod:@"onDownloadEvent"
                           arguments:@{
                             @"event" : @(event),
                             @"gid" : gid ?: @"",
                           }];
    };
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  [self.native invokeMethod:call.method
                  arguments:[call.arguments isKindOfClass:[NSDictionary class]]
                                ? (NSDictionary<NSString*, id>*)call.arguments
                                : nil
                 completion:^(id _Nullable value, NSError* _Nullable error) {
                   if (error == nil) {
                     result(value);
                     return;
                   }
                   NSString* code = error.userInfo[@"code"];
                   if ([code isKindOfClass:[NSString class]] &&
                       [code isEqualToString:@"NOT_IMPLEMENTED"]) {
                     result(FlutterMethodNotImplemented);
                     return;
                   }
                   result([FlutterError errorWithCode:code ?: @"NATIVE_ERROR"
                                              message:error.localizedDescription
                                              details:nil]);
                 }];
}

@end
