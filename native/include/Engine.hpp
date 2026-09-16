#pragma once
#import <Foundation/Foundation.h>
#include <memory>
namespace vv {
class Engine {
    struct Impl;std::unique_ptr<Impl> impl;
public:
    Engine();~Engine();
    NSDictionary *request(NSDictionary *request);
    void environment(bool available);
    void cancelAll();
    void disconnectAll();
};
}
