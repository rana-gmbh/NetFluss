#include "PrivilegedExecution.h"

#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *nf_strdup(const char *string) {
    if (string == NULL) {
        return strdup("");
    }
    return strdup(string);
}

static void nf_append_bytes(char **buffer, size_t *length, const char *bytes, size_t count) {
    if (count == 0) {
        return;
    }

    char *grown = realloc(*buffer, *length + count + 1);
    if (grown == NULL) {
        return;
    }

    memcpy(grown + *length, bytes, count);
    *length += count;
    grown[*length] = '\0';
    *buffer = grown;
}

static void nf_set_output(NetflussPrivilegedCommandResult *result, const char *message) {
    free(result->output);
    result->output = nf_strdup(message);
}

NetflussPrivilegedCommandResult NetflussExecutePrivilegedCommand(const char *command, const char *prompt) {
    NetflussPrivilegedCommandResult result = {
        .authorizationStatus = errAuthorizationInternal,
        .commandStatus = -1,
        .output = NULL
    };

    if (command == NULL || command[0] == '\0') {
        nf_set_output(&result, "Missing command.");
        return result;
    }

    AuthorizationRef authorization = NULL;
    OSStatus authStatus = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authorization);
    if (authStatus != errAuthorizationSuccess || authorization == NULL) {
        result.authorizationStatus = authStatus;
        nf_set_output(&result, "Unable to create authorization reference.");
        return result;
    }

    char toolPath[] = "/bin/sh";
    AuthorizationItem right = {
        .name = kAuthorizationRightExecute,
        .valueLength = sizeof(toolPath),
        .value = toolPath,
        .flags = 0
    };
    AuthorizationRights rights = {
        .count = 1,
        .items = &right
    };

    AuthorizationItem environmentItems[1];
    AuthorizationEnvironment environment = {
        .count = 0,
        .items = NULL
    };

    if (prompt != NULL && prompt[0] != '\0') {
        environmentItems[0].name = kAuthorizationEnvironmentPrompt;
        environmentItems[0].valueLength = strlen(prompt);
        environmentItems[0].value = (void *)prompt;
        environmentItems[0].flags = 0;
        environment.count = 1;
        environment.items = environmentItems;
    }

    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize;
    authStatus = AuthorizationCopyRights(authorization, &rights, environment.count > 0 ? &environment : NULL, flags, NULL);
    if (authStatus != errAuthorizationSuccess) {
        result.authorizationStatus = authStatus;
        nf_set_output(&result, "Authorization was denied.");
        AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        return result;
    }

    char *wrappedCommand = NULL;
    if (asprintf(&wrappedCommand, "%s 2>&1; printf '\\n__NETFLUSS_STATUS__%%d\\n' $?", command) < 0 || wrappedCommand == NULL) {
        result.authorizationStatus = errAuthorizationInternal;
        nf_set_output(&result, "Unable to prepare privileged command.");
        AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        return result;
    }

    char argC[] = "-c";
    char *arguments[] = {
        argC,
        wrappedCommand,
        NULL
    };

    FILE *pipe = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    authStatus = AuthorizationExecuteWithPrivileges(authorization, toolPath, kAuthorizationFlagDefaults, arguments, &pipe);
#pragma clang diagnostic pop
    free(wrappedCommand);

    if (authStatus != errAuthorizationSuccess) {
        result.authorizationStatus = authStatus;
        nf_set_output(&result, "Privileged command could not be started.");
        AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        return result;
    }

    char *output = NULL;
    size_t outputLength = 0;
    char readBuffer[4096];

    while (pipe != NULL) {
        size_t count = fread(readBuffer, 1, sizeof(readBuffer), pipe);
        if (count > 0) {
            nf_append_bytes(&output, &outputLength, readBuffer, count);
        }
        if (count < sizeof(readBuffer)) {
            if (feof(pipe) || ferror(pipe)) {
                break;
            }
        }
    }

    if (pipe != NULL) {
        fclose(pipe);
    }

    result.authorizationStatus = errAuthorizationSuccess;
    result.output = output != NULL ? output : nf_strdup("");

    const char *marker = "__NETFLUSS_STATUS__";
    char *markerPosition = result.output != NULL ? strstr(result.output, marker) : NULL;
    if (markerPosition != NULL) {
        result.commandStatus = (int32_t)strtol(markerPosition + strlen(marker), NULL, 10);
        *markerPosition = '\0';

        size_t trimmedLength = strlen(result.output);
        while (trimmedLength > 0 && (result.output[trimmedLength - 1] == '\n' || result.output[trimmedLength - 1] == '\r')) {
            result.output[trimmedLength - 1] = '\0';
            trimmedLength--;
        }
    }

    AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    return result;
}

void NetflussFreePrivilegedCommandResult(NetflussPrivilegedCommandResult result) {
    free(result.output);
}
