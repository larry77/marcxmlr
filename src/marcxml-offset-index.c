/* C4 screening: namespace-aware Expat pass that retains byte ranges only.
 * No XML trees or canonical rows are built for discarded records.
 * This is optional at build time; unfiltered parsing never calls this code.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Visibility.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef MARCXMLR_HAS_EXPAT
#include <expat.h>
#include "marcxml-expat-compat.h"
#define MARC_NS "http://www.loc.gov/MARC21/slim"
typedef struct { int position; double start; double end; } OffsetHit;
typedef struct {
    XML_Parser parser;
    const char *tag, *subfield, *equals;
    int depth, root_record, root_collection, record_depth;
    int field_depth, subfield_depth, matched;
    int count;
    double record_start;
    OffsetHit *hits;
    size_t used, capacity;
    char *value;
    size_t value_size, value_capacity;
    const char *error;
} OffsetState;

static int name_is(const char *name, const char *local) {
    const char *sep = strchr(name, '|');
    if (!sep) return strcmp(name, local) == 0;
    return (size_t)(sep - name) == strlen(MARC_NS) &&
           strncmp(name, MARC_NS, sep - name) == 0 &&
           strcmp(sep + 1, local) == 0;
}
static const char *attr_is(const XML_Char **atts, const char *key) {
    for (size_t i = 0; atts[i] != NULL; i += 2)
        if (strcmp(atts[i], key) == 0) return atts[i+1];
    return NULL;
}
static void fail(OffsetState *s, const char *reason) {
    s->error = reason;
    XML_StopParser(s->parser, XML_FALSE);
}
static int append_characters(OffsetState *s, const char *buf, size_t n) {
    if (n > SIZE_MAX - s->value_size - 1) return 0;
    size_t required = s->value_size + n + 1;
    if (required > s->value_capacity) {
        size_t capacity = s->value_capacity ? s->value_capacity : 128;
        while (capacity < required) {
            if (capacity > SIZE_MAX / 2) return 0;
            capacity *= 2;
        }
        char *new_value = realloc(s->value, capacity);
        if (!new_value) return 0;
        s->value = new_value;
        s->value_capacity = capacity;
    }
    memcpy(s->value + s->value_size, buf, n);
    s->value_size += n;
    s->value[s->value_size] = '\0';
    return 1;
}
static void XMLCALL start_node(void *ctx, const XML_Char *name,
                               const XML_Char **atts) {
    OffsetState *s = ctx;
    ++s->depth;
    if (s->depth == 1) {
        s->root_record = name_is(name, "record");
        s->root_collection = name_is(name, "collection");
        if (!s->root_record && !s->root_collection)
            fail(s, "root must be MARCXML collection or record");
    }
    if (s->root_collection && s->depth == 2 && !name_is(name, "record")) {
        fail(s, "collection may contain only MARCXML records");
        return;
    }
    if ((s->root_record && s->depth == 1) ||
        (s->root_collection && s->depth == 2 && name_is(name, "record"))) {
        if (s->count == INT_MAX) {
            fail(s, "source contains too many records for integer record IDs");
            return;
        }
        ++s->count;
        s->record_depth = s->depth;
        s->record_start = (double)MARCXMLR_EXPAT_BYTE_INDEX(s->parser);
        s->matched = s->field_depth = s->subfield_depth = 0;
        return;
    }
    if (!s->record_depth || s->matched) return;
    if (s->depth == s->record_depth + 1 && name_is(name, "controlfield")) {
        const char *tag = attr_is(atts, "tag");
        if (!s->subfield && tag && strcmp(tag, s->tag) == 0)
            s->matched = 1;
    } else if (s->depth == s->record_depth + 1 && name_is(name, "datafield")) {
        const char *tag = attr_is(atts, "tag");
        s->field_depth = tag && strcmp(tag, s->tag) == 0 ? s->depth : 0;
        if (s->field_depth && !s->subfield) s->matched = 1;
    } else if (s->field_depth && s->subfield &&
               s->depth == s->record_depth + 2 && name_is(name, "subfield")) {
        const char *code = attr_is(atts, "code");
        if (code && strcmp(code, s->subfield) == 0) {
            s->subfield_depth = s->depth;
            s->value_size = 0;
        }
    }
}
static void XMLCALL character_node(void *ctx, const XML_Char *value, int n) {
    OffsetState *s = ctx;
    if (s->subfield_depth && !s->matched && s->equals &&
        !append_characters(s, value, (size_t)n))
        fail(s, "out of memory collecting subfield value");
}
static void XMLCALL end_node(void *ctx, const XML_Char *name) {
    OffsetState *s = ctx;
    if (s->subfield_depth == s->depth && name_is(name, "subfield")) {
        if (!s->equals || strcmp(s->value_size ? s->value : "", s->equals) == 0)
            s->matched = 1;
        s->subfield_depth = 0;
    }
    if (s->field_depth == s->depth && name_is(name, "datafield"))
        s->field_depth = 0;
    if (s->record_depth == s->depth && name_is(name, "record")) {
        if (s->matched) {
            if (s->used == s->capacity) {
                size_t cap = s->capacity ? s->capacity * 2 : 128;
                if (cap < s->capacity || cap > SIZE_MAX / sizeof(OffsetHit)) {
                    fail(s, "offset index is too large"); return;
                }
                OffsetHit *hits = realloc(s->hits, cap * sizeof(OffsetHit));
                if (!hits) { fail(s, "out of memory storing record offsets"); return; }
                s->hits = hits;
                s->capacity = cap;
            }
            s->hits[s->used++] = (OffsetHit){s->count, s->record_start,
                (double)MARCXMLR_EXPAT_BYTE_INDEX(s->parser) +
                (double)MARCXMLR_EXPAT_BYTE_COUNT(s->parser)};
        }
        s->record_depth = s->matched = 0;
    }
    --s->depth;
}
static void XMLCALL reject_dtd(void *ctx, const XML_Char *a,
                               const XML_Char *b, const XML_Char *c, int d) {
    (void)a; (void)b; (void)c; (void)d;
    fail(ctx, "DTD is unsupported for independent record extraction");
}
#endif

SEXP attribute_visible C_marcxml_offset_index(SEXP path, SEXP tag,
                                               SEXP subfield, SEXP equals) {
#ifndef MARCXMLR_HAS_EXPAT
    (void)path; (void)tag; (void)subfield; (void)equals;
    Rf_error("Record filtering requires Expat support at package build time; reinstall marcxmlr with libexpat development headers and libraries.");
    return R_NilValue;
#else
    const char *filename = CHAR(STRING_ELT(path, 0));
    FILE *file = fopen(filename, "rb");
    if (!file) Rf_error("Cannot open MARCXML for filtering: %s", filename);
    unsigned char head[512];
    size_t len = fread(head, 1, sizeof(head), file);
    int unsupported = (len >= 2 &&
        ((head[0] == 0xff && head[1] == 0xfe) ||
         (head[0] == 0xfe && head[1] == 0xff) ||
         (head[0] == 0x1f && head[1] == 0x8b))) ||
         memchr(head, 0, len) != NULL;
    if (unsupported) {
        fclose(file);
        Rf_error("Offset filtering requires uncompressed UTF-8 MARCXML (no UTF-16 or gzip).");
    }
    rewind(file);
    OffsetState s = {0};
    s.tag = CHAR(STRING_ELT(tag, 0));
    s.subfield = subfield == R_NilValue ? NULL : CHAR(STRING_ELT(subfield, 0));
    s.equals = equals == R_NilValue ? NULL : CHAR(STRING_ELT(equals, 0));
    s.parser = XML_ParserCreateNS("UTF-8", '|');
    if (!s.parser) {
        fclose(file);
        Rf_error("Cannot initialize Expat XML parser.");
    }
    XML_SetUserData(s.parser, &s);
    XML_SetElementHandler(s.parser, start_node, end_node);
    XML_SetCharacterDataHandler(s.parser, character_node);
    XML_SetStartDoctypeDeclHandler(s.parser, reject_dtd);
    XML_SetParamEntityParsing(s.parser, XML_PARAM_ENTITY_PARSING_NEVER);
    char buffer[65536];
    char error_message[512] = {0};
    int failed = 0;
    for (;;) {
        size_t n = fread(buffer, 1, sizeof(buffer), file);
        if (ferror(file)) {
            snprintf(error_message, sizeof(error_message), "Cannot read MARCXML input.");
            failed = 1;
            break;
        }
        int last = feof(file);
        if (XML_Parse(s.parser, buffer, (int)n, last) == XML_STATUS_ERROR) {
            snprintf(error_message, sizeof(error_message),
                     "Expat screening: %s at line %lu",
                     s.error ? s.error : XML_ErrorString(XML_GetErrorCode(s.parser)),
                     (unsigned long)MARCXMLR_EXPAT_LINE_NUMBER(s.parser));
            failed = 1;
            break;
        }
        if (last) break;
    }
    XML_ParserFree(s.parser);
    fclose(file);
    free(s.value);
    if (failed) {
        free(s.hits);
        Rf_error("%s", error_message);
    }
    SEXP result = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP position = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)s.used));
    SEXP starts = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)s.used));
    SEXP ends = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)s.used));
    for (size_t i = 0; i < s.used; ++i) {
        INTEGER(position)[i] = s.hits[i].position;
        REAL(starts)[i] = s.hits[i].start;
        REAL(ends)[i] = s.hits[i].end;
    }
    SET_VECTOR_ELT(result, 0, position);
    SET_VECTOR_ELT(result, 1, starts);
    SET_VECTOR_ELT(result, 2, ends);
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SET_STRING_ELT(names, 0, Rf_mkChar("source_position"));
    SET_STRING_ELT(names, 1, Rf_mkChar("start_byte"));
    SET_STRING_ELT(names, 2, Rf_mkChar("end_byte"));
    Rf_setAttrib(result, R_NamesSymbol, names);
    free(s.hits);
    UNPROTECT(5);
    return result;
#endif
}
