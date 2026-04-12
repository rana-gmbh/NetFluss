#ifndef PRIVILEGED_EXECUTION_H
#define PRIVILEGED_EXECUTION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NetflussPrivilegedCommandResult {
    int32_t authorizationStatus;
    int32_t commandStatus;
    char *output;
} NetflussPrivilegedCommandResult;

NetflussPrivilegedCommandResult NetflussExecutePrivilegedCommand(const char *command, const char *prompt);
void NetflussFreePrivilegedCommandResult(NetflussPrivilegedCommandResult result);

#ifdef __cplusplus
}
#endif

#endif
