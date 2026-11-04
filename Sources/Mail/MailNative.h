#ifndef GAOMAIL_NATIVE_H
#define GAOMAIL_NATIVE_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t uploaded_bytes;
    int code;
    int smtp_final_code;
    char *message;
} GMMailResponse;
GMMailResponse *gm_mail_request(const char *url, const char *username, const char *password,
    const char *oauth_token, const char *command, const uint8_t *upload, size_t upload_length,
    int is_upload, int is_smtp, const char *mail_from, const char *recipients, const char *ca_file);
void gm_mail_response_free(GMMailResponse *response);
#endif
