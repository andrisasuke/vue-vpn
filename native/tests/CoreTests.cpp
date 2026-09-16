// Only parses synthetic profiles in memory. No connect(), sockets, TUN, or DNS mutations.
#include "Policy.hpp"
#include "CoreConfig.hpp"
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
int main(){
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
