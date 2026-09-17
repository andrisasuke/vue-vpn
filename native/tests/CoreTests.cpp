// Only parses synthetic profiles in memory. No connect(), sockets, TUN, or DNS mutations.
#include "Policy.hpp"
#include "CoreConfig.hpp"
#include "CoreError.hpp"
#include <openvpn/client/remotelist.hpp>
#include <openvpn/ssl/sslchoose.hpp>
#include <openvpn/ssl/proto.hpp>
#include <openvpn/frame/frame_init.hpp>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <cassert>
#include <iostream>
#include <memory>
using namespace openvpn::ClientAPI;
class Parser:public OpenVPNClient {
public:
    void event(const Event &)override{assert(false);}
    void log(const LogInfo &)override{}
    void acc_event(const AppCustomControlMessageEvent &)override{assert(false);}
    bool pause_on_connection_timeout()override{assert(false);return false;}
    void external_pki_cert_request(ExternalPKICertRequest &)override{assert(false);}
    void external_pki_sign_request(ExternalPKISignRequest &)override{assert(false);}
};
static std::string text(BIO *bio){char *p=nullptr;auto len=BIO_get_mem_data(bio,&p);return {p,static_cast<size_t>(len)};}
static void numericRemoteEndpoint(){
    // Reproduce a successful resolver callback containing no compatible IPv4
    // endpoint. Use synthetic results only: no DNS, sockets, or VPN connection.
    using Results=openvpn_io::ip::udp::resolver::results_type;
    openvpn::RemoteList remote("192.0.2.10","14180",openvpn::Protocol(openvpn::Protocol::UDPv4),"test");
    auto ipv6=Results::create({openvpn_io::ip::make_address("2001:db8::10"),14180},"192.0.2.10","14180");
    remote.set_endpoint_range(ipv6);
    remote.endpoint_available(nullptr,nullptr,nullptr);
    openvpn_io::ip::udp::endpoint endpoint;
    remote.get_endpoint(endpoint);
    assert(endpoint.address().to_string()=="192.0.2.10"&&endpoint.port()==14180);
}
template<class Transport> static void remoteEndpointLifecycle(const char *proto){
    using Results=typename Transport::resolver::results_type;
    using Endpoint=typename Transport::endpoint;
    auto makeResults=[](const std::vector<Endpoint> &endpoints){
        return Results::create(endpoints.begin(),endpoints.end(),"vpn.example.test","1194");
    };
    auto config=openvpn::OptionList::parse_from_config_static(
        std::string("remote 192.0.2.10 14180 ")+proto+"\nremote 198.51.100.20 443 "+proto+"\n",nullptr);
    openvpn::RemoteList remotes(config,"",0,nullptr,nullptr);
    // Numeric endpoints need no resolver result, including after repeated
    // reconnects, rotation through multiple remotes, and a port override.
    for(unsigned i=0;i<4;++i){
        std::string host,port;openvpn::Protocol protocol;
        assert(remotes.endpoint_available(&host,&port,&protocol));
        Endpoint endpoint;remotes.get_endpoint(endpoint);
        assert(host==(i%2?"198.51.100.20":"192.0.2.10"));
        assert(endpoint.address().to_string()==host);
        assert(endpoint.port()==(i%2?443:14180)&&protocol.is_ipv4());
        remotes.reset_cache_item();
        assert(remotes.endpoint_available(nullptr,nullptr,nullptr));
        remotes.get_endpoint(endpoint);assert(endpoint.address().to_string()==host);
        remotes.next();
    }
    remotes.set_port_override("8443");
    assert(remotes.endpoint_available(nullptr,nullptr,nullptr));
    Endpoint endpoint;remotes.get_endpoint(endpoint);assert(endpoint.port()==8443);
    // A changed server must not retain the previous numeric endpoint.
    remotes.set_server_override("vpn.example.test");
    assert(!remotes.endpoint_available(nullptr,nullptr,nullptr));
    Results empty;
    assert(!remotes.set_endpoint_range(empty));
    auto ipv6=makeResults({{openvpn_io::ip::make_address("2001:db8::10"),8443}});
    assert(!remotes.set_endpoint_range(ipv6));
    // Mixed DNS answers keep IPv4 addresses and preserve address traversal.
    auto mixed=makeResults({{openvpn_io::ip::make_address("2001:db8::10"),8443},
                           {openvpn_io::ip::make_address("203.0.113.10"),8443},
                           {openvpn_io::ip::make_address("203.0.113.20"),8443}});
    assert(remotes.set_endpoint_range(mixed));
    remotes.get_endpoint(endpoint);assert(endpoint.address().to_string()=="203.0.113.10");
    remotes.next();remotes.get_endpoint(endpoint);assert(endpoint.address().to_string()=="203.0.113.20");
    remotes.reset_cache_item();
    assert(!remotes.endpoint_available(nullptr,nullptr,nullptr));
    assert(!remotes.set_endpoint_range(empty));
    auto recovered=makeResults({{openvpn_io::ip::make_address("203.0.113.30"),8443}});
    assert(remotes.set_endpoint_range(recovered));
    remotes.get_endpoint(endpoint);assert(endpoint.address().to_string()=="203.0.113.30");
    const auto transport=openvpn::Protocol::parse(proto,openvpn::Protocol::CLIENT_SUFFIX);
    openvpn::RemoteList incompatible("2001:db8::10","1194",transport,"test");
    assert(!incompatible.endpoint_available(nullptr,nullptr,nullptr));
    // Empty successful results must still leave a numeric IPv4 remote usable.
    openvpn::RemoteList numeric("192.0.2.30","1194",transport,"test");
    assert(numeric.set_endpoint_range(empty));
    numeric.get_endpoint(endpoint);assert(endpoint.address().to_string()=="192.0.2.30");
}
static void connectionDiagnostics(){
    auto result=vv::coreFailure("","socket bind failed: Address already in use");
    assert(result.code=="OPENVPN_ERROR");
    assert(result.message=="OpenVPN connection failed (OPENVPN_ERROR): socket bind failed: Address already in use");
    result=vv::coreFailure("SSL_ERROR","OpenSSLContext: certificate verify failed");
    assert(result.code=="SSL_ERROR"&&result.message.find("certificate verify failed")!=std::string::npos);
    for(auto raw:{""," \n\t\r"}){
        result=vv::coreFailure("",raw);assert(result.code=="OPENVPN_ERROR");
        assert(result.message.find("did not provide an error description")!=std::string::npos);
        assert(result.message.find("()") == std::string::npos);
    }
    result=vv::coreFailure("UNTRUSTED_LABEL_SECRET","socket failure");
    assert(result.code=="OPENVPN_ERROR"&&result.message.find("UNTRUSTED_LABEL_SECRET")==std::string::npos);
    result=vv::coreFailure("AUTH_FAILED","server echoed AUTH_TOKEN_SECRET");
    assert(result.code=="AUTH_FAILED"&&result.message=="PIN, password, or username was rejected.");
    result=vv::coreFailure("","reply from alice-demo carried p[a]ss%42!",{},"alice-demo","p[a]ss%42!");
    assert(result.message.find("alice-demo")==std::string::npos&&result.message.find("p[a]ss%42!")==std::string::npos);
    for(auto raw:{
        "setup failed: password=DO_NOT_EXPOSE\nUNLABELLED_CONTINUATION",
        "setup failed: AUTH-TOKEN DO_NOT_EXPOSE",
        "setup failed: access_token=DO_NOT_EXPOSE",
        "setup failed: refresh_token=DO_NOT_EXPOSE",
        "setup failed: proxy_password=DO_NOT_EXPOSE",
        "setup failed: {\"client_secret\":\"DO_NOT_EXPOSE\"}",
        "setup failed: [auth-token] [DO_NOT_EXPOSE]",
        "setup failed: pin: DO_NOT_EXPOSE",
        "setup failed: -----BEGIN PRIVATE KEY-----\nDO_NOT_EXPOSE",
        "setup failed: <tls-crypt>DO_NOT_EXPOSE</tls-crypt>",
        "setup failed: <key>DO_NOT_EXPOSE", // Incomplete blocks also stay hidden.
        "setup failed: 'DO_NOT_EXPOSE'",
        "setup failed: \"DO_NOT_EXPOSE", // Incomplete quotes.
        "setup failed: [DO_NOT_EXPOSE]",
        "setup failed: https://bob:DO_NOT_EXPOSE@example.test/",
        "setup failed: Bearer DO_NOT_EXPOSE",
        "setup failed: setenv UV_ID DO_NOT_EXPOSE"
    }){
        result=vv::coreFailure("",raw);
        assert(result.message.find("setup failed")!=std::string::npos);
        assert(result.message.find("DO_NOT_EXPOSE")==std::string::npos);
        assert(result.message.find("UNLABELLED_CONTINUATION")==std::string::npos);
    }
    result=vv::coreFailure("","parse error: PRIVATE_FRAGMENT ENV_VALUE",
        "<key>\nPRIVATE_FRAGMENT\n</key>\nsetenv UV_ID ENV_VALUE\n");
    assert(result.message.find("PRIVATE_FRAGMENT")==std::string::npos&&result.message.find("ENV_VALUE")==std::string::npos);
    result=vv::coreFailure("","parse error: AbC123def456GHI789jkl012mno345pqr678==");
    assert(result.message.find("AbC123")==std::string::npos);
    result=vv::coreFailure("",std::string(9000,'x')+"DO_NOT_EXPOSE");
    assert(result.message.find("safe size limit")!=std::string::npos&&result.message.find("DO_NOT_EXPOSE")==std::string::npos);
    result=vv::coreFailure("",std::string(1000,' ')+"bind:\n\tAddress already in use\x01\xff");
    assert(result.message.find("bind: Address already in use")!=std::string::npos);
    assert(std::all_of(result.message.begin(),result.message.end(),[](unsigned char c){return c>=32&&c<127;}));
    std::string longMessage;for(unsigned i=0;i<300;++i)longMessage+="setup error; ";
    result=vv::coreFailure("",longMessage);assert(result.message.size()<850&&result.message.substr(result.message.size()-3)=="...");
}
int main(){
    numericRemoteEndpoint();
    remoteEndpointLifecycle<openvpn_io::ip::udp>("udp4");
    remoteEndpointLifecycle<openvpn_io::ip::tcp>("tcp4-client");
    connectionDiagnostics();
    auto ctx=std::unique_ptr<EVP_PKEY_CTX,decltype(&EVP_PKEY_CTX_free)>(EVP_PKEY_CTX_new_id(EVP_PKEY_RSA,nullptr),EVP_PKEY_CTX_free);
    assert(ctx&&EVP_PKEY_keygen_init(ctx.get())>0&&EVP_PKEY_CTX_set_rsa_keygen_bits(ctx.get(),2048)>0);EVP_PKEY *raw=nullptr;assert(EVP_PKEY_keygen(ctx.get(),&raw)>0);
    auto key=std::unique_ptr<EVP_PKEY,decltype(&EVP_PKEY_free)>(raw,EVP_PKEY_free);
    auto cert=std::unique_ptr<X509,decltype(&X509_free)>(X509_new(),X509_free);assert(cert);
    X509_set_version(cert.get(),2);ASN1_INTEGER_set(X509_get_serialNumber(cert.get()),1);X509_gmtime_adj(X509_getm_notBefore(cert.get()),0);X509_gmtime_adj(X509_getm_notAfter(cert.get()),86400);
    X509_set_pubkey(cert.get(),key.get());auto name=X509_get_subject_name(cert.get());X509_NAME_add_entry_by_txt(name,"CN",MBSTRING_ASC,(const unsigned char*)"vuevpn-unit-test",-1,-1,0);X509_set_issuer_name(cert.get(),name);assert(X509_sign(cert.get(),key.get(),EVP_sha256())>0);
    auto bio=std::unique_ptr<BIO,decltype(&BIO_free)>(BIO_new(BIO_s_mem()),BIO_free);assert(PEM_write_bio_X509(bio.get(),cert.get()));auto pem=text(bio.get());BIO_reset(bio.get());assert(PEM_write_bio_PrivateKey(bio.get(),key.get(),nullptr,nullptr,0,nullptr,nullptr));auto privateKey=text(bio.get());
    const std::string base="client\ndev tun\nremote vpn.example.test 14180 udp\nauth-user-pass\nauth SHA1\ncipher AES-128-CBC\ndata-ciphers AES-128-GCM:AES-128-CBC\ncomp-lzo no\nroute-nopull\nroute 10.7.0.0 255.255.0.0\n<ca>\n"+pem+"</ca>\n<cert>\n"+pem+"</cert>\n<key>\n"+privateKey+"</key>\n";
    Parser parser;auto config=vv::coreConfig(vv::safeConfig(base),true);
    assert(config.compressionMode=="asym");
    assert(vv::coreConfig("client\n",false).compressionMode=="no");
    assert(vv::coreConfig("comp-lzo no\nallow-compression no\n",false).compressionMode=="no");
    assert(vv::coreConfig("compress stub-v2\ncomp-lzo no\n",false).compressionMode=="no");
    assert(vv::coreConfig("compress stub\n",false).compressionMode=="asym");
    assert(vv::coreConfig("comp-lzo yes\n",false).compressionMode=="asym");
    assert(vv::coreConfig("compress lz4\nallow-compression yes\n",false).compressionMode=="asym");
    assert(vv::coreConfig("# comp-lzo no\n<key>\ncomp-lzo no\n</key>\n",false).compressionMode=="no");
    assert(vv::coreConfig("comp-lzo \"no\" # legacy framing\n",false).compressionMode=="asym");
    // Exercise Core's actual pushed-option parser and legacy packet framing in memory.
    // eval_config alone cannot catch errors that occur when server settings arrive.
    openvpn::ProtoContextCompressionOptions compression;
    compression.parse_compression_mode(config.compressionMode);
    assert(compression.is_comp_asym());
    auto pushed=openvpn::OptionList::parse_from_config_static("comp-lzo no\n",nullptr);
    openvpn::ProtoContext::ProtoConfig protocol;
    protocol.parse_pushed_compression(pushed,compression);
    assert(protocol.comp_ctx.type()==openvpn::CompressContext::LZO_STUB);
    auto frame=openvpn::frame_init_simple(2048);
    openvpn::SessionStats::Ptr stats(new openvpn::SessionStats);
    auto codec=protocol.comp_ctx.new_compressor(frame,stats);
    std::string payload(512,'A');payload[0]=0x45;
    openvpn::BufferAllocated packet;frame->prepare(openvpn::Frame::DECRYPT_WORK,packet);packet.write(payload.data(),payload.size());
    codec->compress(packet,true);
    assert(packet.size()==payload.size()+1&&packet[0]==0xfa);
    codec->decompress(packet);
    assert(packet.size()==payload.size()&&std::memcmp(packet.c_data(),payload.data(),payload.size())==0);
    // Even if a legacy server negotiates a real compressor, VueVPN only receives
    // compressed payloads: a compressible uplink payload must stay uncompressed.
    protocol.parse_pushed_compression(openvpn::OptionList::parse_from_config_static("compress lz4\n",nullptr),compression);
    assert(protocol.comp_ctx.asym());
    codec=protocol.comp_ctx.new_compressor(frame,stats);
    frame->prepare(openvpn::Frame::DECRYPT_WORK,packet);packet.write(payload.data(),payload.size());
    codec->compress(packet,true);assert(packet.size()==payload.size()+1&&packet[0]==0xfb);
    codec->decompress(packet);assert(packet.size()==payload.size()&&std::memcmp(packet.c_data(),payload.data(),payload.size())==0);
    auto serverCodec=openvpn::CompressContext(openvpn::CompressContext::LZ4,false).new_compressor(frame,stats);
    serverCodec->compress(packet,true);assert(packet.size()<payload.size());
    codec->decompress(packet);assert(packet.size()==payload.size()&&std::memcmp(packet.c_data(),payload.data(),payload.size())==0);
    auto evaluated=parser.eval_config(config);if(evaluated.error)std::cerr<<evaluated.message<<'\n';assert(!evaluated.error);assert(!evaluated.externalPki);assert(!evaluated.autologin);assert(evaluated.allowPasswordSave);
    assert(evaluated.remoteProto.find("UDP")!=std::string::npos||evaluated.remoteProto.find("udp")!=std::string::npos);
    Parser pritunl;config.content=vv::safeConfig("ignore-unknown-option data-ciphers\nsetenv UV_ID synthetic-id\nsetenv UV_NAME synthetic-name\n"+base);
    auto compatible=pritunl.eval_config(config);if(compatible.error)std::cerr<<compatible.message<<'\n';assert(!compatible.error);assert(!compatible.autologin);assert(compatible.allowPasswordSave);
    Parser noSave;config.content=vv::safeConfig(base+"setenv ALLOW_PASSWORD_SAVE 0\n");auto forbidden=noSave.eval_config(config);assert(!forbidden.error&&!forbidden.allowPasswordSave);
    Parser invalid;config.content="client\ndev tap\nremote vpn.example.test\n";assert(invalid.eval_config(config).error);
    std::cout<<"Embedded OpenVPN 3 parser unit tests passed; no VPN connection attempted.\n";
}
