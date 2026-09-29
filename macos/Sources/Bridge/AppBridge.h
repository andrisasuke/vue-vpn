#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Existing AppBridge.mm ABI. Returned buffers must be erased/freed with vv_free.
char *vv_request(const char *json);
char *vv_service(const char *operation);
char *vv_helper_identity(void);
char *vv_keychain(const char *operation, const char *profile_id, const char *secret);
void vv_free(char *response);

#ifdef __cplusplus
}
#endif
