#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "Protocol.h"
#include "ServicePolicy.hpp"
#include <mutex>
#include <memory>
#include <cstring>

static NSXPCConnection *connection;
static std::mutex connectionMutex;
static std::mutex replacementMutex;
static bool replacing=false;
static bool needsRegistration=false;
static bool registrationAttempted=false;
static NSString *replacementError;
static bool replacementRetryable=false;
static NSData *encoded(id value){return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];}
static NSDictionary *failure(NSString *code,NSString *message){return @{ @"error":@{@"code":code,@"message":message}};}
static char *copied(id object){NSData *data=encoded(object);char *s=(char *)malloc(data.length+1);memcpy(s,data.bytes,data.length);s[data.length]=0;return s;}
static NSXPCConnection *helperConnection(){
    std::lock_guard<std::mutex> lock(connectionMutex);
    if(!connection){
        NSString *requirement=VVSigningRequirement(@"com.vuevpn.helper");if(!requirement)return nil;
        NSXPCConnection *c=[[NSXPCConnection alloc] initWithMachServiceName:VV_SERVICE options:NSXPCConnectionPrivileged];
        c.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(VueVPNHelperProtocol)];
        [c setCodeSigningRequirement:requirement];
        __weak NSXPCConnection *weak=c;
        c.invalidationHandler=^{std::lock_guard<std::mutex> lock(connectionMutex);if(connection==weak)connection=nil;};
        c.interruptionHandler=^{[weak invalidate];};[c resume];connection=c;
    }return connection;
}
static void invalidateConnection(NSXPCConnection *expected=nil){
    NSXPCConnection *old;
    {std::lock_guard<std::mutex> lock(connectionMutex);if(expected&&connection!=expected)return;old=connection;connection=nil;}
    [old invalidate]; // Never hold the mutex while invoking invalidation handlers.
}
extern "C" char *vv_helper_identity(){@autoreleasepool{
    NSBundle *bundle=NSBundle.mainBundle;
    // A standalone executable has no bundled helper to install.
    if(![bundle.bundlePath.pathExtension isEqualToString:@"app"])return copied(@{@"buildId":NSNull.null});
    NSURL *plistURL=[bundle.bundleURL URLByAppendingPathComponent:@"Contents/Library/LaunchDaemons/com.vuevpn.helper.plist"];
    NSDictionary *plist=[NSDictionary dictionaryWithContentsOfURL:plistURL error:nil];
    if(![plist[@"Label"] isEqual:VV_SERVICE]||![plist[@"BundleProgram"] isEqual:@"Contents/MacOS/vuevpn-helper"]||
       ![plist[@"MachServices"] isKindOfClass:NSDictionary.class]||![plist[@"MachServices"][VV_SERVICE] isEqual:@YES])
        return copied(failure(@"helper_bundle",@"The bundled helper service definition is missing or invalid. Install the complete signed VueVPN.app from artifacts."));
    NSURL *url=[bundle.bundleURL URLByAppendingPathComponent:@"Contents/MacOS/vuevpn-helper"];
    SecStaticCodeRef code=nullptr;SecRequirementRef requirement=nullptr;
    NSString *req=VVSigningRequirement(@"com.vuevpn.helper");
    if(!req||SecStaticCodeCreateWithPath((__bridge CFURLRef)url,kSecCSDefaultFlags,&code)!=errSecSuccess)
        return copied(failure(@"helper_bundle",@"The bundled VPN helper is missing or unsigned. Install a complete signed VueVPN.app."));
    OSStatus status=SecRequirementCreateWithString((__bridge CFStringRef)req,kSecCSDefaultFlags,&requirement);
    if(status==errSecSuccess)status=SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement);
    NSString *build=status==errSecSuccess?VVCodeBuildId(code):nil;
    if(requirement)CFRelease(requirement);CFRelease(code);
    if(!build)return copied(failure(@"helper_bundle",@"The bundled VPN helper signature is invalid. Install a complete signed VueVPN.app."));
    return copied(@{@"buildId":build});
}}
extern "C" void vv_free(char *s){if(s){auto length=strlen(s);volatile char *p=s;while(length--)*p++=0;free(s);}}
struct ReplyState {std::mutex mutex;NSData *answer=nil;bool failed=false,completed=false;dispatch_semaphore_t done=dispatch_semaphore_create(0);};
extern "C" char *vv_request(const char *json){@autoreleasepool{
    NSData *payload=[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    NSXPCConnection *c=helperConnection();if(!c)return copied(failure(@"signing",@"VueVPN must be built and signed as an app before connecting to its helper."));
    auto reply=std::make_shared<ReplyState>();
    id<VueVPNHelperProtocol> proxy=[c remoteObjectProxyWithErrorHandler:^(NSError *){std::lock_guard<std::mutex> lock(reply->mutex);if(reply->completed)return;reply->failed=true;reply->completed=true;dispatch_semaphore_signal(reply->done);}];
    [proxy request:payload withReply:^(NSData *data){std::lock_guard<std::mutex> lock(reply->mutex);if(reply->completed)return;reply->answer=data;reply->completed=true;dispatch_semaphore_signal(reply->done);}];
    if(dispatch_semaphore_wait(reply->done,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))!=0){invalidateConnection(c);return copied(failure(@"helper_timeout",@"The VPN helper did not respond. Reconnecting to the helper…"));}
    NSData *answer;bool failed;
    {std::lock_guard<std::mutex> lock(reply->mutex);answer=reply->answer;failed=reply->failed;reply->completed=true;}
    if(failed||!answer){invalidateConnection(c);return copied(failure(@"helper_unavailable",@"The VPN helper connection was interrupted. Reconnecting…"));}
    id object=[NSJSONSerialization JSONObjectWithData:answer options:0 error:nil];return copied(object?:failure(@"helper_protocol",@"Invalid helper response."));
}}
extern "C" char *vv_service(const char *operation){@autoreleasepool{
    NSString *op=[NSString stringWithUTF8String:operation];SMAppService *service=[SMAppService daemonServiceWithPlistName:VV_PLIST];NSError *error=nil;
    if([op isEqualToString:@"reconnect"])invalidateConnection();
    {
        std::lock_guard<std::mutex> lock(replacementMutex);
        if(replacing)return copied(@{@"status":@"updating",@"message":@"Updating the VPN helper…"});
        if([op isEqualToString:@"reset_update"]||[op isEqualToString:@"register"]||[op isEqualToString:@"unregister"]){replacementError=nil;replacementRetryable=false;}
        if([op isEqualToString:@"unregister"]){needsRegistration=false;registrationAttempted=false;}
        if(replacementError&&![op isEqualToString:@"settings"])return copied(@{@"status":replacementRetryable?@"update_retry_pending":@"update_failed",@"message":replacementError});
        if([op isEqualToString:@"replace"]){replacing=true;needsRegistration=false;registrationAttempted=false;}
        if(needsRegistration&&([op isEqualToString:@"status"]||[op isEqualToString:@"reset_update"])){
            // A register call can finish after its immediate return. Observe the
            // fresh system status instead of masking it with our pending flag.
            auto status=service.status;
            if(registrationAttempted&&(status==SMAppServiceStatusEnabled||status==SMAppServiceStatusRequiresApproval))needsRegistration=false;
            else return copied(@{@"status":@"registration_pending",@"message":@"Registering the updated VPN helper…"});
        }
    }
    if([op isEqualToString:@"replace"]){
        invalidateConnection();
        // Await the unregister operation before re-registering. Running process
        // identity is verified separately because service/process state can lag.
        [service unregisterWithCompletionHandler:^(NSError *unregisterError){@autoreleasepool{
            NSString *message=nil;
            if(unregisterError&&unregisterError.code!=kSMErrorJobNotFound)
                message=[NSString stringWithFormat:@"Could not stop the previous VPN helper (ServiceManagement error %ld). Retry the helper update.",(long)unregisterError.code];
            // Continue registration via the coordinator using a fresh service
            // instance. Keep this phase explicit, including across Retry clicks.
            std::lock_guard<std::mutex> lock(replacementMutex);replacementError=message;replacementRetryable=message&&vv::retryableRegistrationError(unregisterError.code);needsRegistration=message==nil;replacing=false;
        }}];
        return copied(@{@"status":@"updating",@"message":@"Updating the VPN helper…"});
    }
    if([op isEqualToString:@"register_update"]){
        BOOL registered=[service registerAndReturnError:&error];
        {std::lock_guard<std::mutex> lock(replacementMutex);registrationAttempted=true;}
        auto status=service.status;
        if(status==SMAppServiceStatusRequiresApproval||(!registered&&error.code==kSMErrorLaunchDeniedByUser)){
            std::lock_guard<std::mutex> lock(replacementMutex);needsRegistration=false;
            return copied(@{@"status":@"requires_approval",@"message":@"Approve VueVPN in System Settings → General → Login Items & Extensions."});
        }
        if(!registered&&error.code!=kSMErrorAlreadyRegistered){
            NSString *message=[NSString stringWithFormat:@"Could not register the VPN helper (ServiceManagement error %ld).",(long)error.code];
            if(vv::retryableRegistrationError(error.code)){
                std::lock_guard<std::mutex> lock(replacementMutex);needsRegistration=true;
                return copied(@{@"status":@"registration_pending",@"message":message});
            }
            return copied(failure(@"helper_setup",message));
        }
        std::lock_guard<std::mutex> lock(replacementMutex);
        needsRegistration=status!=SMAppServiceStatusEnabled;
        if(needsRegistration)return copied(@{@"status":@"registration_pending",@"message":@"Waiting for macOS to register the updated VPN helper…"});
        return copied(@{@"status":@"enabled",@"message":@"VPN helper registered. Verifying the running version…"});
    }
    if([op isEqualToString:@"register"]){invalidateConnection();if(![service registerAndReturnError:&error]&&error.code!=kSMErrorAlreadyRegistered&&service.status!=SMAppServiceStatusRequiresApproval)return copied(failure(@"helper_setup",error.localizedDescription));}
    else if([op isEqualToString:@"unregister"]){if(![service unregisterAndReturnError:&error])return copied(failure(@"helper_setup",error.localizedDescription));invalidateConnection();}
    else if([op isEqualToString:@"settings"]){dispatch_async(dispatch_get_main_queue(),^{[SMAppService openSystemSettingsLoginItems];});}
    if([op isEqualToString:@"register"]){std::lock_guard<std::mutex> lock(replacementMutex);needsRegistration=false;}
    NSString *status=@"not_registered",*message=@"Enable the VPN helper to create tunnels and manage routing.";
    switch(service.status){case SMAppServiceStatusEnabled:status=@"enabled";message=@"VPN helper enabled.";break;case SMAppServiceStatusRequiresApproval:status=@"requires_approval";message=@"Approve VueVPN in System Settings → General → Login Items & Extensions.";break;case SMAppServiceStatusNotFound:status=@"not_found";message=@"Install the packaged VueVPN.app in /Applications before enabling its helper.";break;default:break;}
    return copied(@{@"status":status,@"message":message});
}}
extern "C" char *vv_keychain(const char *operation,const char *profileId,const char *secret){@autoreleasepool{
    NSString *op=[NSString stringWithUTF8String:operation],*account=[NSString stringWithUTF8String:profileId];
    NSMutableDictionary *query=[@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"com.vuevpn.desktop.credentials",(__bridge id)kSecAttrAccount:account} mutableCopy];
    OSStatus status=errSecSuccess;CFTypeRef result=nullptr;
    if([op isEqualToString:@"set"]){NSData *data=[[NSString stringWithUTF8String:secret] dataUsingEncoding:NSUTF8StringEncoding];status=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});if(status==errSecItemNotFound){query[(__bridge id)kSecValueData]=data;query[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;status=SecItemAdd((__bridge CFDictionaryRef)query,nullptr);}}
    else if([op isEqualToString:@"delete"]){status=SecItemDelete((__bridge CFDictionaryRef)query);if(status==errSecItemNotFound)status=errSecSuccess;}
    else {query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;LAContext *context=[LAContext new];context.interactionNotAllowed=YES;query[(__bridge id)kSecUseAuthenticationContext]=context;
        if([op isEqualToString:@"get"])query[(__bridge id)kSecReturnData]=@YES;else query[(__bridge id)kSecReturnAttributes]=@YES;
        status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);
        if(status==errSecItemNotFound)return copied(@{@"found":@NO});
    }
    if(status!=errSecSuccess){if(result)CFRelease(result);return copied(failure(@"keychain",@"Keychain access failed or is locked. Enter your PIN manually or unlock your login Keychain."));}
    id answer=@{@"found":@YES};if(result&&[op isEqualToString:@"get"]){NSString *data=[[NSString alloc]initWithData:(__bridge NSData *)result encoding:NSUTF8StringEncoding];answer=@{@"found":@YES,@"secret":data?:@""};}
    if(result)CFRelease(result);return copied(answer);
}}
