#include <AudioToolbox/AudioToolbox.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define SLOT_COUNT 4
#define CHUNK_BYTES 8820
#define MAX_FRAME 1048576

typedef struct {
    int socket;
    AudioQueueRef queue;
    AudioQueueBufferRef free[SLOT_COUNT];
    int free_count;
    int active;
    int ending;
    int running;
    int socket_error;
    pthread_mutex_t lock;
    pthread_cond_t drained;
} Bridge;

static int write_all(int socket, const void *data, size_t length)
{
    const uint8_t *bytes = data;
    while (length > 0) {
        ssize_t count = send(socket, bytes, length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += count;
        length -= (size_t)count;
    }
    return 0;
}

static int write_frame(int socket, const void *data, uint32_t length)
{
    uint32_t header = htonl(length);
    if (write_all(socket, &header, sizeof(header)) < 0) return -1;
    return write_all(socket, data, length);
}

static int read_all(int socket, void *data, size_t length)
{
    uint8_t *bytes = data;
    while (length > 0) {
        ssize_t count = recv(socket, bytes, length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += count;
        length -= (size_t)count;
    }
    return 0;
}

static int read_frame(int socket, uint8_t *data, uint32_t *length)
{
    uint32_t header;
    if (read_all(socket, &header, sizeof(header)) < 0) return -1;
    *length = ntohl(header);
    if (*length < 1 || *length > MAX_FRAME) return -2;
    return read_all(socket, data, *length);
}

static void report_error(int socket, const char *message)
{
    uint8_t frame[512];
    size_t length = strlen(message);
    if (length > sizeof(frame) - 1) length = sizeof(frame) - 1;
    frame[0] = 'X';
    memcpy(frame + 1, message, length);
    (void)write_frame(socket, frame, (uint32_t)length + 1);
}

static void audio_done(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    Bridge *bridge = context;
    uint8_t ready = 'R';
    int request;
    (void)queue;

    pthread_mutex_lock(&bridge->lock);
    bridge->free[bridge->free_count++] = buffer;
    bridge->active--;
    request = !bridge->ending && !bridge->socket_error;
    if (bridge->active == 0) pthread_cond_signal(&bridge->drained);
    pthread_mutex_unlock(&bridge->lock);

    if (request && write_frame(bridge->socket, &ready, 1) < 0) {
        pthread_mutex_lock(&bridge->lock);
        bridge->socket_error = errno ? errno : EIO;
        pthread_cond_signal(&bridge->drained);
        pthread_mutex_unlock(&bridge->lock);
        shutdown(bridge->socket, SHUT_RDWR);
    }
}

static void running_changed(void *context, AudioQueueRef queue, AudioQueuePropertyID property)
{
    Bridge *bridge = context;
    UInt32 running = 0;
    UInt32 size = sizeof(running);
    OSStatus status;
    (void)property;

    status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size);
    pthread_mutex_lock(&bridge->lock);
    if (status == noErr)
        bridge->running = running != 0;
    else
        bridge->socket_error = EIO;
    pthread_cond_broadcast(&bridge->drained);
    pthread_mutex_unlock(&bridge->lock);
    if (status != noErr) shutdown(bridge->socket, SHUT_RDWR);
}

static int connect_local(int port)
{
    int socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    int enabled = 1;
    if (socket_fd < 0) return -1;
    (void)setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static int run_bridge(int port)
{
    Bridge bridge;
    AudioStreamBasicDescription format;
    uint8_t *frame = NULL;
    int result = 1;
    int started = 0;
    int i;

    memset(&bridge, 0, sizeof(bridge));
    bridge.socket = -1;
    pthread_mutex_init(&bridge.lock, NULL);
    pthread_cond_init(&bridge.drained, NULL);

    bridge.socket = connect_local(port);
    if (bridge.socket < 0) {
        fprintf(stderr, "audio bridge connection failed: %s\n", strerror(errno));
        goto cleanup;
    }

    memset(&format, 0, sizeof(format));
    format.mSampleRate = 44100.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger |
                          kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;

    OSStatus status = AudioQueueNewOutput(&format, audio_done, &bridge, NULL, NULL, 0,
                                          &bridge.queue);
    if (status != noErr) {
        char message[96];
        snprintf(message, sizeof(message), "AudioQueueNewOutput failed: %d", (int)status);
        report_error(bridge.socket, message);
        goto cleanup;
    }
    status = AudioQueueAddPropertyListener(bridge.queue, kAudioQueueProperty_IsRunning,
                                           running_changed, &bridge);
    if (status != noErr) {
        char message[96];
        snprintf(message, sizeof(message), "AudioQueueAddPropertyListener failed: %d",
                 (int)status);
        report_error(bridge.socket, message);
        goto cleanup;
    }

    for (i = 0; i < SLOT_COUNT; i++) {
        status = AudioQueueAllocateBuffer(bridge.queue, CHUNK_BYTES, &bridge.free[i]);
        if (status != noErr) {
            char message[96];
            snprintf(message, sizeof(message), "AudioQueueAllocateBuffer failed: %d",
                     (int)status);
            report_error(bridge.socket, message);
            goto cleanup;
        }
        bridge.free_count++;
    }

    frame = malloc(MAX_FRAME);
    if (frame == NULL) {
        report_error(bridge.socket, "audio bridge allocation failed");
        goto cleanup;
    }

    for (i = 0; i < SLOT_COUNT; i++) {
        uint8_t ready = 'R';
        if (write_frame(bridge.socket, &ready, 1) < 0) goto cleanup;
    }

    for (;;) {
        uint32_t length;
        int read_result = read_frame(bridge.socket, frame, &length);
        if (read_result == -2) {
            report_error(bridge.socket, "bad frame");
            goto cleanup;
        }
        if (read_result < 0) goto cleanup;

        if (frame[0] == 'E') {
            pthread_mutex_lock(&bridge.lock);
            bridge.ending = 1;
            pthread_mutex_unlock(&bridge.lock);

            if (started) {
                status = AudioQueueStop(bridge.queue, false);
                if (status != noErr) {
                    char message[96];
                    snprintf(message, sizeof(message), "AudioQueueStop failed: %d", (int)status);
                    report_error(bridge.socket, message);
                    goto cleanup;
                }
                pthread_mutex_lock(&bridge.lock);
                while (bridge.running && !bridge.socket_error)
                    pthread_cond_wait(&bridge.drained, &bridge.lock);
                int socket_error = bridge.socket_error;
                pthread_mutex_unlock(&bridge.lock);
                if (socket_error) goto cleanup;
            }
            uint8_t done = 'D';
            if (write_frame(bridge.socket, &done, 1) < 0) goto cleanup;
            result = 0;
            break;
        }

        if (frame[0] != 'A' || length < 2 || length - 1 > CHUNK_BYTES ||
            ((length - 1) & 1) != 0) {
            report_error(bridge.socket, "bad audio command");
            goto cleanup;
        }

        pthread_mutex_lock(&bridge.lock);
        if (bridge.free_count == 0) {
            pthread_mutex_unlock(&bridge.lock);
            report_error(bridge.socket, "audio without credit");
            goto cleanup;
        }
        AudioQueueBufferRef buffer = bridge.free[--bridge.free_count];
        bridge.active++;
        pthread_mutex_unlock(&bridge.lock);

        memcpy(buffer->mAudioData, frame + 1, length - 1);
        buffer->mAudioDataByteSize = length - 1;
        status = AudioQueueEnqueueBuffer(bridge.queue, buffer, 0, NULL);
        if (status != noErr) {
            char message[96];
            pthread_mutex_lock(&bridge.lock);
            bridge.free[bridge.free_count++] = buffer;
            bridge.active--;
            pthread_mutex_unlock(&bridge.lock);
            snprintf(message, sizeof(message), "AudioQueueEnqueueBuffer failed: %d",
                     (int)status);
            report_error(bridge.socket, message);
            goto cleanup;
        }

        if (!started) {
            pthread_mutex_lock(&bridge.lock);
            bridge.running = 1;
            pthread_mutex_unlock(&bridge.lock);
            status = AudioQueueStart(bridge.queue, NULL);
            if (status != noErr) {
                char message[96];
                pthread_mutex_lock(&bridge.lock);
                bridge.running = 0;
                pthread_mutex_unlock(&bridge.lock);
                snprintf(message, sizeof(message), "AudioQueueStart failed: %d", (int)status);
                report_error(bridge.socket, message);
                goto cleanup;
            }
            started = 1;
        }
    }

cleanup:
    pthread_mutex_lock(&bridge.lock);
    bridge.ending = 1;
    pthread_mutex_unlock(&bridge.lock);
    if (bridge.queue != NULL) {
        (void)AudioQueueRemovePropertyListener(bridge.queue, kAudioQueueProperty_IsRunning,
                                               running_changed, &bridge);
        if (result != 0 && started) (void)AudioQueueStop(bridge.queue, true);
        (void)AudioQueueDispose(bridge.queue, true);
    }
    free(frame);
    if (bridge.socket >= 0) close(bridge.socket);
    pthread_cond_destroy(&bridge.drained);
    pthread_mutex_destroy(&bridge.lock);
    return result;
}

int main(int argc, char **argv)
{
    char *end;
    long port;
    signal(SIGPIPE, SIG_IGN);
    if (argc != 2) {
        fprintf(stderr, "usage: %s PORT\n", argv[0]);
        return 1;
    }
    errno = 0;
    port = strtol(argv[1], &end, 10);
    if (errno || *end != '\0' || port < 1 || port > 65535) {
        fprintf(stderr, "invalid port\n");
        return 1;
    }
    return run_bridge((int)port);
}
