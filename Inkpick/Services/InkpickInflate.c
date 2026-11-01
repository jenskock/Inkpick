#include <stdint.h>
#include <string.h>
#include <zlib.h>

int inkpick_inflate_raw(const uint8_t *src, int src_len,
                        uint8_t *dst, int dst_cap, int *dst_len) {
    z_stream stream;
    int status;

    if (src == NULL || dst == NULL || dst_len == NULL || src_len < 0 || dst_cap < 0) {
        return -1;
    }

    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        return -1;
    }

    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_cap;
    status = inflate(&stream, Z_FINISH);
    *dst_len = (int)stream.total_out;
    inflateEnd(&stream);
    return status == Z_STREAM_END ? 0 : -1;
}
