//
//  FluxoEngineText.c
//  Fluxo
//
//  Text of the renditions: language tags, playlist attribute text, and subtitles converted to WebVTT.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// ISO 639-2 (bibliographic or terminology) codes of the languages that have an ISO 639-1 code, which
// BCP 47 (the HLS LANGUAGE attribute) prefers. Other three-letter codes are valid BCP 47 as they are.
static const char *const fluxo_language_codes[][2] = {
    {"alb", "sq"}, {"ara", "ar"}, {"arm", "hy"}, {"aze", "az"}, {"baq", "eu"}, {"bel", "be"}, {"ben", "bn"},
    {"bos", "bs"}, {"bul", "bg"}, {"bur", "my"}, {"cat", "ca"}, {"ces", "cs"}, {"chi", "zh"}, {"cym", "cy"},
    {"cze", "cs"}, {"dan", "da"}, {"deu", "de"}, {"dut", "nl"}, {"ell", "el"}, {"eng", "en"}, {"est", "et"},
    {"eus", "eu"}, {"fas", "fa"}, {"fin", "fi"}, {"fra", "fr"}, {"fre", "fr"}, {"geo", "ka"}, {"ger", "de"},
    {"gle", "ga"}, {"glg", "gl"}, {"gre", "el"}, {"guj", "gu"}, {"heb", "he"}, {"hin", "hi"}, {"hrv", "hr"},
    {"hun", "hu"}, {"hye", "hy"}, {"ice", "is"}, {"ind", "id"}, {"isl", "is"}, {"ita", "it"}, {"jpn", "ja"},
    {"kan", "kn"}, {"kat", "ka"}, {"kaz", "kk"}, {"khm", "km"}, {"kor", "ko"}, {"kur", "ku"}, {"lao", "lo"},
    {"lat", "la"}, {"lav", "lv"}, {"lit", "lt"}, {"ltz", "lb"}, {"mac", "mk"}, {"mal", "ml"}, {"mar", "mr"},
    {"may", "ms"}, {"mkd", "mk"}, {"mlt", "mt"}, {"mon", "mn"}, {"msa", "ms"}, {"mya", "my"}, {"nep", "ne"},
    {"nld", "nl"}, {"nob", "nb"}, {"nno", "nn"}, {"nor", "no"}, {"pan", "pa"}, {"per", "fa"}, {"pol", "pl"},
    {"por", "pt"}, {"pus", "ps"}, {"ron", "ro"}, {"rum", "ro"}, {"rus", "ru"}, {"sin", "si"}, {"slk", "sk"},
    {"slo", "sk"}, {"slv", "sl"}, {"som", "so"}, {"spa", "es"}, {"sqi", "sq"}, {"srp", "sr"}, {"swa", "sw"},
    {"swe", "sv"}, {"tam", "ta"}, {"tel", "te"}, {"tgl", "tl"}, {"tha", "th"}, {"tur", "tr"}, {"ukr", "uk"},
    {"urd", "ur"}, {"uzb", "uz"}, {"vie", "vi"}, {"wel", "cy"}, {"zho", "zh"},
};

// The BCP 47 tag of a stream's "language" tag ("eng" -> "en", "pt-BR" stays), or "" when it has none.
void fluxo_language_tag(const char *language, char *buffer, size_t size) {
    buffer[0] = '\0';
    if (language == NULL) {
        return;
    }
    char lower[16];
    size_t length = 0;
    for (const char *c = language; *c != '\0' && length + 1 < sizeof(lower); c++) {
        char ch = *c;
        if (ch == '_') {
            ch = '-';
        }
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-')) {
            return;
        }
        lower[length++] = (ch >= 'A' && ch <= 'Z') ? (char)(ch - 'A' + 'a') : ch;
    }
    lower[length] = '\0';
    // "und" (undetermined), "mis", "mul", "zxx" and "qaa"-"qtz" (local use) name no language.
    if (length == 0 || strcmp(lower, "und") == 0 || strcmp(lower, "mis") == 0 || strcmp(lower, "mul") == 0
        || strcmp(lower, "zxx") == 0 || (length == 3 && lower[0] == 'q' && lower[1] >= 'a' && lower[1] <= 't')) {
        return;
    }
    if (length == 3) {
        for (size_t i = 0; i < sizeof(fluxo_language_codes) / sizeof(fluxo_language_codes[0]); i++) {
            if (strcmp(lower, fluxo_language_codes[i][0]) == 0) {
                snprintf(buffer, size, "%s", fluxo_language_codes[i][1]);
                return;
            }
        }
    }
    snprintf(buffer, size, "%s", lower);
}

// Copies a stream title into a quoted-string of a playlist attribute: no quotes, no control characters,
// cut at a UTF-8 character boundary.
void fluxo_attribute_text(const char *text, char *buffer, size_t size) {
    size_t length = 0;
    if (text != NULL) {
        const unsigned char *c = (const unsigned char *)text;
        for (; *c != '\0' && length + 1 < size; c++) {
            unsigned char ch = *c;
            if (ch < 0x20 || ch == 0x7F) {
                ch = ' ';
            } else if (ch == '"') {
                ch = '\'';
            }
            buffer[length++] = (char)ch;
        }
        // When the text was cut, do not end in the middle of a multi-byte character. A complete character at
        // the end stays.
        if (*c != '\0') {
            size_t lead = length;
            while (lead > 0 && ((unsigned char)buffer[lead - 1] & 0xC0) == 0x80) {
                lead--;
            }
            if (lead > 0 && ((unsigned char)buffer[lead - 1] & 0xC0) == 0xC0) {
                unsigned char first = (unsigned char)buffer[lead - 1];
                size_t expected = (first & 0xE0) == 0xC0 ? 2 : (first & 0xF0) == 0xE0 ? 3 : (first & 0xF8) == 0xF0 ? 4 : 1;
                if (length - (lead - 1) < expected) {
                    length = lead - 1;
                }
            }
        }
        while (length > 0 && buffer[length - 1] == ' ') {
            length--;
        }
    }
    buffer[length] = '\0';
}

// Appends `text` to the growing buffer, keeping it NUL-terminated. Returns 0, or a negative error.
static int fluxo_append(char **buffer, size_t *length, size_t *capacity, const char *text, size_t count) {
    if (*length + count + 1 > *capacity) {
        size_t needed = *length + count + 1;
        size_t grown = *capacity > 0 ? *capacity * 2 : 256;
        char *larger = realloc(*buffer, grown > needed ? grown : needed);
        if (larger == NULL) {
            return AVERROR(ENOMEM);
        }
        *buffer = larger;
        *capacity = grown > needed ? grown : needed;
    }
    memcpy(*buffer + *length, text, count);
    *length += count;
    (*buffer)[*length] = '\0';
    return 0;
}

// The WebVTT tags kept from SubRip and WebVTT text (others are dropped, their text kept).
static int fluxo_vtt_tag(const char *tag, size_t length, char *normalized) {
    // tag points at '<', length includes '<' and '>'.
    if (length == 3 || length == 4) {
        int closing = tag[1] == '/';
        char name = tag[closing ? 2 : 1];
        if (name >= 'A' && name <= 'Z') {
            name = (char)(name - 'A' + 'a');
        }
        if ((size_t)(closing ? 4 : 3) == length && (name == 'i' || name == 'b' || name == 'u')) {
            snprintf(normalized, 5, closing ? "</%c>" : "<%c>", name);
            return 1;
        }
    }
    return 0;
}

// The WebVTT cue text of a text subtitle packet, or NULL when it has none (an empty or drawing-only event).
// SubRip and WebVTT keep <i>, <b> and <u>; ASS / SSA override blocks are removed except italics and bold.
char *fluxo_subtitle_text(enum AVCodecID codec_id, const uint8_t *data, int size) {
    if (data == NULL || size <= 0) {
        return NULL;
    }
    const char *text = (const char *)data;
    size_t length = (size_t)size;
    if (codec_id == AV_CODEC_ID_MOV_TEXT) {
        // 3GPP timed text: a 16-bit length, then UTF-8 text (style boxes follow and are ignored).
        if (size < 2) {
            return NULL;
        }
        size_t declared = ((size_t)data[0] << 8) | data[1];
        text += 2;
        length = declared < (size_t)size - 2 ? declared : (size_t)size - 2;
    } else if (codec_id == AV_CODEC_ID_ASS || codec_id == AV_CODEC_ID_SSA) {
        // Matroska ASS events: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
        int commas = 0;
        size_t i = 0;
        while (i < length && commas < 8) {
            if (text[i] == ',') {
                commas++;
            }
            i++;
        }
        if (commas < 8) {
            // Not the Matroska layout: take the text as it is.
            i = 0;
        }
        text += i;
        length -= i;
    }

    int is_ass = codec_id == AV_CODEC_ID_ASS || codec_id == AV_CODEC_ID_SSA;
    int keeps_entities = codec_id == AV_CODEC_ID_WEBVTT;
    char *out = NULL;
    size_t out_length = 0;
    size_t capacity = 0;
    int italic = 0;
    int bold = 0;
    int drawing = 0;
    int pending_newline = 0;
    int ret = 0;

    for (size_t i = 0; i < length && ret == 0; i++) {
        char c = text[i];
        if (c == '\0') {
            break;
        }
        if (is_ass && c == '{') {
            // An override block: {\i1}, {\b0}, {\p1} (drawing), {\an8}, ...
            size_t end = i + 1;
            while (end < length && text[end] != '}') {
                end++;
            }
            for (size_t j = i + 1; j + 1 < end; j++) {
                if (text[j] != '\\') {
                    continue;
                }
                char tag = text[j + 1];
                char value = j + 2 < end ? text[j + 2] : '\0';
                if ((tag == 'i' || tag == 'b') && (value == '0' || value == '1')) {
                    int *state = tag == 'i' ? &italic : &bold;
                    if (*state != (value == '1') && !drawing) {
                        *state = value == '1';
                        const char *html = tag == 'i' ? (*state ? "<i>" : "</i>") : (*state ? "<b>" : "</b>");
                        ret = fluxo_append(&out, &out_length, &capacity, html, strlen(html));
                    }
                } else if (tag == 'p' && value >= '0' && value <= '9') {
                    drawing = value != '0';
                }
            }
            i = end;
            continue;
        }
        if (drawing) {
            continue;
        }
        if (is_ass && c == '\\' && i + 1 < length && (text[i + 1] == 'N' || text[i + 1] == 'n' || text[i + 1] == 'h')) {
            if (text[i + 1] == 'h') {
                ret = fluxo_append(&out, &out_length, &capacity, " ", 1);
            } else {
                pending_newline = out_length > 0;
            }
            i++;
            continue;
        }
        if (!is_ass && c == '{' && i + 1 < length && text[i + 1] == '\\') {
            // SubRip position tags ({\an8}).
            while (i < length && text[i] != '}') {
                i++;
            }
            continue;
        }
        if (c == '\r') {
            continue;
        }
        if (c == '\n') {
            pending_newline = out_length > 0;
            continue;
        }
        if (pending_newline) {
            // One line break at most: an empty line would end the cue.
            ret = fluxo_append(&out, &out_length, &capacity, "\n", 1);
            pending_newline = 0;
            if (ret < 0) {
                break;
            }
        }
        if (c == '<' && !is_ass) {
            size_t end = i + 1;
            while (end < length && end - i < 64 && text[end] != '>' && text[end] != '<') {
                end++;
            }
            if (end < length && text[end] == '>') {
                char normalized[5];
                if (fluxo_vtt_tag(text + i, end - i + 1, normalized)) {
                    ret = fluxo_append(&out, &out_length, &capacity, normalized, strlen(normalized));
                } else if (keeps_entities) {
                    // WebVTT input: its other tags (<c.yellow>, <v Name>, timestamps) are valid as they are.
                    ret = fluxo_append(&out, &out_length, &capacity, text + i, end - i + 1);
                }
                // Other SubRip tags (<font color=...>) are dropped.
                i = end;
                continue;
            }
            ret = fluxo_append(&out, &out_length, &capacity, "&lt;", 4);
            continue;
        }
        if (c == '<') {
            ret = fluxo_append(&out, &out_length, &capacity, "&lt;", 4);
        } else if (c == '>' && !keeps_entities) {
            ret = fluxo_append(&out, &out_length, &capacity, "&gt;", 4);
        } else if (c == '&' && !keeps_entities) {
            ret = fluxo_append(&out, &out_length, &capacity, "&amp;", 5);
        } else {
            ret = fluxo_append(&out, &out_length, &capacity, &c, 1);
        }
    }
    if (ret == 0 && italic) {
        ret = fluxo_append(&out, &out_length, &capacity, "</i>", 4);
    }
    if (ret == 0 && bold) {
        ret = fluxo_append(&out, &out_length, &capacity, "</b>", 4);
    }
    // Trailing spaces only.
    while (ret == 0 && out_length > 0 && (out[out_length - 1] == ' ' || out[out_length - 1] == '\t')) {
        out[--out_length] = '\0';
    }
    if (ret < 0 || out_length == 0) {
        free(out);
        return NULL;
    }
    return out;
}
