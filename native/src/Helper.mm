#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <Network/Network.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#include "Protocol.h"
#include "Engine.hpp"
#include "Policy.hpp"
#include "Connectivity.hpp"
#include <atomic>
#include <mutex>
#include <unistd.h>

static NSData *encode(id obj){return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];}
static NSDictionary *error(NSString *code,NSString *message){return @{@"error":@{@"code":code,@"message":message}};}
static bool consoleUser(uid_t user){uid_t console=0;gid_t group=0;CFStringRef name=SCDynamicStoreCopyConsoleUser(nullptr,&console,&group);if(name)CFRelease(name);return user>=501&&user==console;}


@interface Helper : NSObject<NSXPCListenerDelegate,VueVPNHelperProtocol> {
@public
    std::unique_ptr<vv::Engine> engine;
    dispatch_queue_t queue;
    NSXPCConnection *owner;
    NSString *buildId;
    std::atomic<bool> asleep;
    dispatch_queue_t networkQueue;
    vv::LinkReadiness readiness;
    uint64_t ownerGeneration;
}
@end
@implementation Helper
- (instancetype)init {self=[super init];if(self){
    SecCodeRef code=nullptr;if(SecCodeCopySelf(kSecCSDefaultFlags,&code)==errSecSuccess){buildId=VVCodeBuildId(code);CFRelease(code);}
    if(!buildId)throw vv::Error("signing","Cannot identify the signed VPN helper.");
    engine=std::make_unique<vv::Engine>();queue=dispatch_queue_create("com.vuevpn.helper.requests",DISPATCH_QUEUE_SERIAL);asleep=false;ownerGeneration=0;networkQueue=dispatch_queue_create("com.vuevpn.helper.network",DISPATCH_QUEUE_SERIAL);
}return self;}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    if(!consoleUser(connection.effectiveUserIdentifier))return NO;
    NSString *requirement=VVSigningRequirement(@"com.vuevpn.desktop");if(!requirement)return NO;
    __block uint64_t generation;
    @synchronized(self){if(owner)return NO;owner=connection;generation=++ownerGeneration;}
    [connection setCodeSigningRequirement:requirement];
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(VueVPNHelperProtocol)];connection.exportedObject=self;
    __weak Helper *weak=self;__weak NSXPCConnection *weakConnection=connection;
    connection.invalidationHandler=^{Helper *s=weak;if(!s)return;
        // Never wait for route cleanup to release the XPC owner. A late callback
        // from an old connection must not cancel a newly authenticated owner's work.
        @synchronized(s){if(s->ownerGeneration==generation){s->engine->cancelAll();s->owner=nil;}}
    };
    connection.interruptionHandler=^{[weakConnection invalidate];};[connection resume];return YES;
}
- (void)request:(NSData *)data withReply:(void (^)(NSData *))reply {
    NSXPCConnection *caller=NSXPCConnection.currentConnection;
    @synchronized(self){if(caller!=owner||!consoleUser(caller.effectiveUserIdentifier)){reply(encode(error(@"unauthorized",@"Only the active console user can control VueVPN.")));[caller invalidate];return;}}
    if(data.length>9*1024*1024){reply(encode(error(@"limit",@"Helper request exceeds the size limit.")));return;}
    dispatch_async(queue,^{@autoreleasepool{try{
        id request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![request isKindOfClass:NSDictionary.class]||![request[@"version"] isEqual:@(VV_PROTOCOL_VERSION)])throw vv::Error("protocol","Unsupported helper protocol.");
        NSMutableDictionary *response;
        @synchronized(self){
            if(owner!=caller)throw vv::Error("unauthorized","The helper connection was closed.");
            response=[engine->request(request) mutableCopy];
        }
        response[@"buildId"]=buildId;
        reply(encode(response));
    }catch(const vv::Error &e){reply(encode(error([NSString stringWithUTF8String:e.code.c_str()],[NSString stringWithUTF8String:e.what()])));}
     catch(const std::exception &){reply(encode(error(@"helper_error",@"The VPN helper could not complete the request.")));}
    }});
}
@end
struct PowerContext {Helper *helper;io_connect_t port;};
static void linkCallback(SCDynamicStoreRef,CFArrayRef keys,void *context) {
    Helper *helper=(__bridge Helper *)context;
    // Notification delivery shares the readiness timer's serial queue. Link
    // changes invalidate a transport even if DHCP assigns the same IP/router,
    // or the down/up interval was shorter than the one-second polling interval.
    for(NSString *key in (__bridge NSArray *)keys) {
        NSArray<NSString *> *parts=[key componentsSeparatedByString:@"/"];
        if(parts.count==5&&helper->readiness.interfaceChanged(parts[3].UTF8String)) {
            helper->engine->environment(false);break;
        }
    }
}
static void powerCallback(void *context,io_service_t,natural_t type,void *argument){auto *p=(PowerContext*)context;
    if(type==kIOMessageCanSystemSleep){IOAllowPowerChange(p->port,(long)argument);}
    if(type==kIOMessageSystemWillSleep||type==kIOMessageSystemHasPoweredOn){
        Helper *helper=p->helper;helper->asleep=type==kIOMessageSystemWillSleep;
        dispatch_async(helper->networkQueue,^{helper->readiness.reset();helper->engine->environment(false);});
        // Acknowledge immediately; VPN cleanup must not hold up macOS sleep.
        if(type==kIOMessageSystemWillSleep)IOAllowPowerChange(p->port,(long)argument);
    }
}
int main(){@autoreleasepool{
    if(geteuid()!=0)return 77;
    try {
        Helper *helper=[Helper new];NSXPCListener *listener=[[NSXPCListener alloc]initWithMachServiceName:VV_SERVICE];listener.delegate=helper;[listener resume];
        SCDynamicStoreContext linkContext{0,(__bridge void *)helper,nullptr,nullptr,nullptr};
        SCDynamicStoreRef linkStore=SCDynamicStoreCreate(nullptr,CFSTR("VueVPN link changes"),linkCallback,&linkContext);
        if(!linkStore||!SCDynamicStoreSetNotificationKeys(linkStore,nullptr,(__bridge CFArrayRef)@[@"State:/Network/Interface/[^/]+/Link",@"State:/Network/Interface/[^/]+/AirPort"])||
            !SCDynamicStoreSetDispatchQueue(linkStore,helper->networkQueue))throw vv::Error("network_monitor","Cannot monitor physical network changes.");
        // Re-read physical service state and live interface addresses, including
        // while offline. Cached NWPath readiness from before sleep is not enough.
        dispatch_source_t networkTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,helper->networkQueue);
        dispatch_source_set_timer(networkTimer,DISPATCH_TIME_NOW,NSEC_PER_SEC,100*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(networkTimer,^{
            auto link=helper->asleep?std::nullopt:vv::physicalLink();
            bool ready=helper->readiness.observe(link,std::chrono::steady_clock::now());
            helper->engine->environment(ready);
        });dispatch_resume(networkTimer);
        IONotificationPortRef notifications=nullptr;io_object_t notifier=0;PowerContext power{helper,0};power.port=IORegisterForSystemPower(&power,&notifications,powerCallback,&notifier);
        if(power.port)CFRunLoopAddSource(CFRunLoopGetMain(),IONotificationPortGetRunLoopSource(notifications),kCFRunLoopCommonModes);
        signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
        dispatch_source_t terminate=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(terminate,^{helper->engine->disconnectAll();exit(0);});dispatch_resume(terminate);
        dispatch_source_t interrupt=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());dispatch_source_set_event_handler(interrupt,^{helper->engine->disconnectAll();exit(0);});dispatch_resume(interrupt);
        [[NSRunLoop mainRunLoop]run];
    }catch(const std::exception &){return 70;}
    return 0;
}}
