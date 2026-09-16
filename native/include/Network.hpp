#pragma once
#include "Policy.hpp"
#include <memory>

namespace vv {
struct Tunnel {std::string address,gateway,interface;unsigned prefix=32,mtu=1500;bool net30=false;};
class Network {
    struct Impl;std::unique_ptr<Impl> impl;
public:
    Network();~Network();
    void reserve(const std::string &id,const Policy &policy);
    bool protect(const std::string &id,int socket,const std::string &endpoint);
    int establish(const std::string &id,Tunnel &tunnel,Policy &effective);
    void teardown(const std::string &id,bool release);
};
}
