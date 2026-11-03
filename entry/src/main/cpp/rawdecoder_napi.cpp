#include <cstdlib>
#include <cstring>
#include <node_api.h>
#include "libraw/libraw.h"

struct InputBytes {
    void* data;
    size_t length;
};

static bool ReadBytes(napi_env env, napi_value value, InputBytes& out)
{
    bool isTyped = false;
    if (napi_is_typedarray(env, value, &isTyped) != napi_ok || !isTyped) {
        return false;
    }
    napi_typedarray_type type;
    size_t length = 0;
    void* data = nullptr;
    napi_value arrayBuffer = nullptr;
    size_t offset = 0;
    if (napi_get_typedarray_info(env, value, &type, &length, &data, &arrayBuffer, &offset) != napi_ok) {
        return false;
    }
    if (type != napi_uint8_array || data == nullptr || length == 0) {
        return false;
    }
    out.data = data;
    out.length = length;
    return true;
}

static napi_value MakeUint8Array(napi_env env, const unsigned char* data, size_t length)
{
    napi_value buffer = nullptr;
    void* dst = nullptr;
    if (napi_create_arraybuffer(env, length, &dst, &buffer) != napi_ok) {
        return nullptr;
    }
    std::memcpy(dst, data, length);
    napi_value result = nullptr;
    if (napi_create_typedarray(env, napi_uint8_array, length, buffer, 0, &result) != napi_ok) {
        return nullptr;
    }
    return result;
}

static napi_value ExtractPreview(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    InputBytes input { nullptr, 0 };
    if (!ReadBytes(env, argv[0], input)) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    libraw_data_t* raw = libraw_init(0);
    if (raw == nullptr || libraw_open_buffer(raw, input.data, input.length) != LIBRAW_SUCCESS ||
        libraw_unpack_thumb(raw) != LIBRAW_SUCCESS || raw->thumbnail.tformat != LIBRAW_THUMBNAIL_JPEG ||
        raw->thumbnail.thumb == nullptr || raw->thumbnail.tlength <= 0) {
        if (raw != nullptr) {
            libraw_close(raw);
        }
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    napi_value result = MakeUint8Array(env,
        reinterpret_cast<const unsigned char*>(raw->thumbnail.thumb), raw->thumbnail.tlength);
    libraw_close(raw);
    return result;
}

static napi_value DecodeInternal(napi_env env, napi_callback_info info, float threshold)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
        return nullptr;
    }
    InputBytes input { nullptr, 0 };
    if (!ReadBytes(env, argv[0], input)) {
        return nullptr;
    }
    libraw_data_t* raw = libraw_init(0);
    if (raw == nullptr || libraw_open_buffer(raw, input.data, input.length) != LIBRAW_SUCCESS) {
        if (raw != nullptr) {
            libraw_close(raw);
        }
        return nullptr;
    }
    raw->params.use_camera_wb = 1;
    raw->params.use_auto_wb = 0;
    raw->params.output_color = 1;
    raw->params.output_bps = 8;
    raw->params.no_auto_bright = 0;
    raw->params.auto_bright_thr = threshold;
    if (libraw_unpack(raw) != LIBRAW_SUCCESS || libraw_dcraw_process(raw) != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return nullptr;
    }
    libraw_processed_image_t* image = libraw_dcraw_make_mem_image(raw, nullptr);
    if (image == nullptr || image->width <= 0 || image->height <= 0 || image->bits != 8) {
        if (image != nullptr) {
            libraw_dcraw_clear_mem(image);
        }
        libraw_close(raw);
        return nullptr;
    }
    const int32_t width = image->width;
    const int32_t height = image->height;
    const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
    napi_value result = nullptr;
    napi_create_array(env, &result);
    napi_value value = nullptr;
    napi_create_int32(env, width, &value);
    napi_set_element(env, result, 0, value);
    napi_create_int32(env, height, &value);
    napi_set_element(env, result, 1, value);
    const unsigned char* src = image->data;
    for (size_t i = 0; i < count; i++) {
        uint32_t argb = 0xFF000000;
        if (image->colors >= 3) {
            argb |= static_cast<uint32_t>(src[i * image->colors]) << 16;
            argb |= static_cast<uint32_t>(src[i * image->colors + 1]) << 8;
            argb |= static_cast<uint32_t>(src[i * image->colors + 2]);
        } else {
            argb |= static_cast<uint32_t>(src[i]) << 16;
            argb |= static_cast<uint32_t>(src[i]) << 8;
            argb |= static_cast<uint32_t>(src[i]);
        }
        napi_create_uint32(env, argb, &value);
        napi_set_element(env, result, i + 2, value);
    }
    libraw_dcraw_clear_mem(image);
    libraw_close(raw);
    return result;
}

static napi_value Decode(napi_env env, napi_callback_info info)
{
    return DecodeInternal(env, info, 0.01F);
}

static napi_value DecodeWithThreshold(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
        return nullptr;
    }
    double value = 0.01;
    napi_get_value_double(env, argv[1], &value);
    const float threshold = value > 0.0 && value < 0.5 ? static_cast<float>(value) : 0.01F;
    return DecodeInternal(env, info, threshold);
}

static napi_value DecodeLinearInternal(napi_env env, napi_callback_info info, bool srgb)
{
    size_t argc = 5;
    napi_value argv[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
        return nullptr;
    }
    InputBytes input { nullptr, 0 };
    if (!ReadBytes(env, argv[0], input)) {
        return nullptr;
    }
    double m0 = 1.0;
    double m1 = 1.0;
    double m2 = 1.0;
    bool half = false;
    if (argc >= 4) {
        napi_get_value_double(env, argv[1], &m0);
        napi_get_value_double(env, argv[2], &m1);
        napi_get_value_double(env, argv[3], &m2);
    }
    if (argc >= 5) {
        napi_get_value_bool(env, argv[4], &half);
    }
    libraw_data_t* raw = libraw_init(0);
    if (raw == nullptr || libraw_open_buffer(raw, input.data, input.length) != LIBRAW_SUCCESS) {
        if (raw != nullptr) {
            libraw_close(raw);
        }
        return nullptr;
    }
    if (srgb) {
        raw->params.use_camera_wb = 1;
        raw->params.use_auto_wb = 0;
        raw->params.output_color = 1;
    } else {
        raw->params.use_camera_wb = 0;
        raw->params.use_auto_wb = 0;
        raw->params.output_color = 0;
        raw->params.user_mul[0] = static_cast<float>(m0);
        raw->params.user_mul[1] = static_cast<float>(m1);
        raw->params.user_mul[2] = static_cast<float>(m2);
        raw->params.user_mul[3] = static_cast<float>(m1);
    }
    raw->params.output_bps = 16;
    raw->params.gamm[0] = 1.0;
    raw->params.gamm[1] = 1.0;
    raw->params.no_auto_bright = 1;
    raw->params.bright = 1.0;
    raw->params.highlight = 0;
    raw->params.user_qual = 3;
    raw->params.half_size = half ? 1 : 0;
    if (libraw_unpack(raw) != LIBRAW_SUCCESS || libraw_dcraw_process(raw) != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return nullptr;
    }
    libraw_processed_image_t* image = libraw_dcraw_make_mem_image(raw, nullptr);
    if (image == nullptr || image->width <= 0 || image->height <= 0 || image->bits != 16) {
        if (image != nullptr) {
            libraw_dcraw_clear_mem(image);
        }
        libraw_close(raw);
        return nullptr;
    }
    const int32_t width = image->width;
    const int32_t height = image->height;
    const size_t nbytes = static_cast<size_t>(width) * static_cast<size_t>(height) *
        image->colors * 2u;
    napi_value buffer = nullptr;
    void* dst = nullptr;
    if (napi_create_arraybuffer(env, 8 + nbytes, &dst, &buffer) != napi_ok || dst == nullptr) {
        libraw_dcraw_clear_mem(image);
        libraw_close(raw);
        return nullptr;
    }
    unsigned char* base = static_cast<unsigned char*>(dst);
    int32_t* head = reinterpret_cast<int32_t*>(base);
    head[0] = width;
    head[1] = height;
    std::memcpy(base + 8, image->data, nbytes);
    libraw_dcraw_clear_mem(image);
    libraw_close(raw);
    return buffer;
}

static napi_value DecodeLinear(napi_env env, napi_callback_info info)
{
    return DecodeLinearInternal(env, info, false);
}

static napi_value DecodeLinearSrgb(napi_env env, napi_callback_info info)
{
    return DecodeLinearInternal(env, info, true);
}

static napi_value FreeLinear(napi_env env, napi_callback_info info)
{
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        { "extractPreview", nullptr, ExtractPreview, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "decode", nullptr, Decode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "decodeWithThr", nullptr, DecodeWithThreshold, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "decodeLinear", nullptr, DecodeLinear, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "decodeLinearSrgb", nullptr, DecodeLinearSrgb, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "freeLinear", nullptr, FreeLinear, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

EXTERN_C_START
static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "rawdecoder",
    .nm_priv = nullptr,
    .reserved = { 0 }
};
EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterRawDecoder(void)
{
    napi_module_register(&module);
}
