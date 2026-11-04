#include "MailNative.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define GM_MAX_RESPONSE (128UL * 1024 * 1024)
typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
    int failed;
    int is_smtp;
    int smtp_data_started;
    int smtp_final_code;
    const uint8_t *upload;
    size_t upload_length;
    size_t upload_offset;
} GMBuffer;
static pthread_once_t gm_once = PTHREAD_ONCE_INIT;
static void gm_initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static int gm_append(GMBuffer *b, const char *data, size_t length) {
    if (length > GM_MAX_RESPONSE - b->length) { b->failed = 1; return 0; }
    size_t wanted = b->length + length;
    if (wanted > b->capacity) {
        size_t capacity = wanted * 2 + 4096;
        uint8_t *next = realloc(b->bytes, capacity);
        if (!next) { b->failed = 1; return 0; }
        b->bytes = next; b->capacity = capacity;
    }
    memcpy(b->bytes + b->length, data, length); b->length = wanted;
    return 1;
}
static size_t gm_ignore(char *data, size_t size, size_t count, void *opaque) {
    (void)data; (void)opaque; return size * count;
}
static size_t gm_read(char *output, size_t size, size_t count, void *opaque) {
    GMBuffer *b = opaque;
    size_t available = b->upload_length - b->upload_offset, wanted = size * count;
    if (wanted > available) wanted = available;
    if (wanted) memcpy(output, b->upload + b->upload_offset, wanted);
    b->upload_offset += wanted; return wanted;
}
static int gm_inbound(CURL *handle, curl_infotype type, char *data, size_t size, void *opaque) {
    (void)handle;
    // Capture server protocol responses in memory, including IMAP literal lines.
    // Discard ALL outgoing/debug/TLS trace events, which may include credentials.
    if (type == CURLINFO_HEADER_IN) {
        GMBuffer *buffer = opaque;
        gm_append(buffer, data, size);
        if (buffer->is_smtp && size >= 4 && data[3] == ' ') {
            int code = (data[0] - '0') * 100 + (data[1] - '0') * 10 + data[2] - '0';
            if (code == 354) buffer->smtp_data_started = 1;
            else if (buffer->smtp_data_started && buffer->smtp_final_code == 0 && code >= 200 && code <= 599) buffer->smtp_final_code = code;
        }
    }
    return 0;
}
static int gm_progress(void *opaque, curl_off_t total_down, curl_off_t down, curl_off_t total_up, curl_off_t up) {
    (void)total_down; (void)down; (void)total_up; (void)up;
    return ((GMBuffer *)opaque)->failed ? 1 : 0;
}
GMMailResponse *gm_mail_request(const char *url, const char *username, const char *password,
    const char *oauth_token, const char *command, const uint8_t *upload, size_t upload_length,
    int is_upload, int is_smtp, const char *mail_from, const char *recipients, const char *ca_file) {
    pthread_once(&gm_once, gm_initialize);
    GMMailResponse *result = calloc(1, sizeof(GMMailResponse));
    if (!result) return NULL;
    CURL *curl = curl_easy_init();
    if (!curl) { result->code = CURLE_OUT_OF_MEMORY; return result; }
    GMBuffer buffer = {0};
    buffer.upload = upload; buffer.upload_length = upload_length; buffer.is_smtp = is_smtp;
    char error[CURL_ERROR_SIZE] = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERNAME, username);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, password);
    if (oauth_token && oauth_token[0]) {
        curl_easy_setopt(curl, CURLOPT_XOAUTH2_BEARER, oauth_token);
        curl_easy_setopt(curl, CURLOPT_LOGIN_OPTIONS, "AUTH=XOAUTH2");
    }
    curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    if (ca_file && ca_file[0]) curl_easy_setopt(curl, CURLOPT_CAINFO, ca_file);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, is_upload ? 180L : 90L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, gm_ignore);
    curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
    curl_easy_setopt(curl, CURLOPT_DEBUGFUNCTION, gm_inbound);
    curl_easy_setopt(curl, CURLOPT_DEBUGDATA, &buffer);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, gm_progress);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &buffer);
    if (command && command[0]) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, command);
    struct curl_slist *addresses = NULL;
    char *address_copy = NULL;
    if (is_upload) {
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(curl, CURLOPT_READFUNCTION, gm_read);
        curl_easy_setopt(curl, CURLOPT_READDATA, &buffer);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)upload_length);
        if (is_smtp) {
            curl_easy_setopt(curl, CURLOPT_MAIL_FROM, mail_from);
            curl_easy_setopt(curl, CURLOPT_MAIL_RCPT_ALLOWFAILS, 0L);
            address_copy = strdup(recipients ? recipients : "");
            if (address_copy) {
                char *save = NULL;
                for (char *line = strtok_r(address_copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
                    addresses = curl_slist_append(addresses, line);
                }
                curl_easy_setopt(curl, CURLOPT_MAIL_RCPT, addresses);
            }
        }
    }
    result->code = (int)curl_easy_perform(curl);
    if (buffer.failed) result->code = CURLE_FILESIZE_EXCEEDED;
    result->message = strdup(buffer.failed ? "邮件响应超过 128 MB 限制，请通过网页下载大附件。" : (error[0] ? error : curl_easy_strerror((CURLcode)result->code)));
    curl_easy_cleanup(curl);
    result->bytes = buffer.bytes; result->length = buffer.length;
    result->uploaded_bytes = buffer.upload_offset;
    result->smtp_final_code = buffer.smtp_final_code;
    curl_slist_free_all(addresses);
    free(address_copy);
    return result;
}
void gm_mail_response_free(GMMailResponse *response) {
    if (!response) return;
    free(response->bytes); free(response->message); free(response);
}
