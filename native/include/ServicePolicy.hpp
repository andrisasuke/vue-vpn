#pragma once
#include <ServiceManagement/SMErrors.h>

namespace vv {
inline bool retryableRegistrationError(long code) {
    // A valid bundle can temporarily lose its service record during replacement.
    // Signature, invalid-tool and authorization errors require user action.
    return code==kSMErrorJobNotFound||code==kSMErrorJobPlistNotFound||
        code==kSMErrorServiceUnavailable||code==kSMErrorInternalFailure;
}
}
