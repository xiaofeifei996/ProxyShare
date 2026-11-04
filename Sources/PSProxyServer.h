#ifndef PS_PROXY_SERVER_H
#define PS_PROXY_SERVER_H

#import <Foundation/Foundation.h>

@interface PSProxyServer : NSObject
- (BOOL)startWithSOCKS:(uint16_t)socksPort http:(uint16_t)httpPort error:(NSString **)err;
- (void)stop;
@end

#endif
