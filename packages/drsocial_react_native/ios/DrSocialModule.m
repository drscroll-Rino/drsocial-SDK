// The Objective-C declarations React Native reads for the Swift module (DrSocialModule.swift).
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_REMAP_MODULE(DrSocial, DrSocialModule, RCTEventEmitter)

RCT_EXTERN__BLOCKING_SYNCHRONOUS_METHOD(isStarted)
RCT_EXTERN_METHOD(identify:(NSString *)externalId options:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(signOut:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(track:(NSString *)name props:(NSDictionary *)props)
RCT_EXTERN_METHOD(screen:(NSString *)name)
RCT_EXTERN_METHOD(reportError:(NSString *)type message:(NSString *)message frames:(NSArray *)frames)
RCT_EXTERN_METHOD(flush:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(siteUrl:(NSString *)url resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN__BLOCKING_SYNCHRONOUS_METHOD(value:(NSString *)key)
RCT_EXTERN__BLOCKING_SYNCHRONOUS_METHOD(update)
RCT_EXTERN_METHOD(askReviewIfDue:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(messages:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(messageEvent:(NSString *)id kind:(NSString *)kind answer:(NSString *)answer resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(requestPush:(BOOL)provisional)
RCT_EXTERN_METHOD(liveActivity:(NSString *)kind type:(NSString *)type activity:(NSString *)activity token:(NSString *)token)

@end
