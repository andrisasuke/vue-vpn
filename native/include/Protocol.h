#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#define VV_SERVICE @"com.vuevpn.helper"
#define VV_PLIST @"com.vuevpn.helper.plist"
#define VV_PROTOCOL_VERSION 1
@protocol VueVPNHelperProtocol
- (void)request:(NSData *)request withReply:(void (^)(NSData *))reply;
@end

// Read the signed executable's identity, not its display version. Capture this
// once in the helper at launch so replacing the app on disk cannot change it.
static inline NSString *VVCodeBuildId(SecStaticCodeRef code) {
    CFDictionaryRef info=nullptr;
    if(SecCodeCopySigningInformation(code,kSecCSDefaultFlags,&info)!=errSecSuccess)return nil;
    NSData *hash=[(__bridge NSDictionary *)info objectForKey:(__bridge NSString *)kSecCodeInfoUnique];
    NSMutableString *value=[NSMutableString string];
    if([hash isKindOfClass:NSData.class])for(NSUInteger i=0;i<hash.length;++i)[value appendFormat:@"%02x",((const unsigned char *)hash.bytes)[i]];
    CFRelease(info);return value.length?value:nil;
}

// Authentication is enforced by XPC on every message, not by a reusable PID lookup.
static inline NSString *VVSigningRequirement(NSString *identifier) {
    SecCodeRef own=nullptr;CFDictionaryRef info=nullptr;
    if(SecCodeCopySelf(kSecCSDefaultFlags,&own)!=errSecSuccess)return nil;
    OSStatus result=SecCodeCopySigningInformation(own,kSecCSSigningInformation,&info);CFRelease(own);
    if(result!=errSecSuccess)return nil;
    NSString *team=[(__bridge NSDictionary *)info objectForKey:(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    NSString *req=team.length?[NSString stringWithFormat:@"identifier \"%@\" and anchor apple generic and certificate leaf[subject.OU] = \"%@\"",identifier,team]:nil;
    CFRelease(info);return req;
}
