/* Standalone Expat screening/indexing helper for an R feasibility test.
 * Compile: cc -O2 -std=c99 -Wall -Wextra -o record_offset_index record_offset_index.c -lexpat
 * Output: source_position TAB start_byte TAB end_byte (end exclusive).
 * Only UTF-8, uncompressed, DTD-free MARCXML. Offsets are zero-based.
 */
#include <expat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

#define MARCNS "http://www.loc.gov/MARC21/slim"
typedef struct { size_t ordinal; int64_t start, end; } Hit;
typedef struct {
    XML_Parser parser;
    const char *tag, *subfield, *equals;
    int depth, root_record, root_collection, record_depth, field_depth, subfield_depth;
    size_t count, size, capacity;
    int matched;
    int64_t rec_start;
    Hit *hits;
    char *value;
    size_t value_len, value_cap;
    const char *error;
} State;

static int marc_name(const char *name, const char *wanted) {
    const char *pipe = strchr(name, '|');
    if (!pipe) return strcmp(name, wanted) == 0;
    return strlen(MARCNS) == (size_t)(pipe - name) &&
           strncmp(name, MARCNS, pipe - name) == 0 &&
           strcmp(pipe + 1, wanted) == 0;
}
static const char *attribute(const XML_Char **atts, const char *wanted) {
    for (size_t i = 0; atts[i]; i += 2)
        if (strcmp(atts[i], wanted) == 0) return atts[i + 1];
    return NULL;
}
static void stop(State *s, const char *why) {
    s->error = why;
    XML_StopParser(s->parser, XML_FALSE);
}
static int append_value(State *s, const char *ptr, int len) {
    size_t n = (size_t)len;
    if (s->value_len + n + 1 > s->value_cap) {
        size_t cap = s->value_cap ? s->value_cap * 2 : 128;
        while (cap < s->value_len + n + 1) cap *= 2;
        char *p = realloc(s->value, cap);
        if (!p) return 0;
        s->value = p; s->value_cap = cap;
    }
    memcpy(s->value + s->value_len, ptr, n);
    s->value_len += n;
    s->value[s->value_len] = '\0';
    return 1;
}
static void XMLCALL start_element(void *userdata, const char *name, const char **atts) {
    State *s = (State *)userdata;
    s->depth++;
    if (s->depth == 1) {
        s->root_record = marc_name(name, "record");
        s->root_collection = marc_name(name, "collection");
        if (!s->root_record && !s->root_collection)
            stop(s, "root is not a MARCXML collection or record");
    }
    if ((s->root_record && s->depth == 1) ||
        (s->root_collection && s->depth == 2 && marc_name(name, "record"))) {
        s->count++;
        s->record_depth = s->depth;
        s->rec_start = (int64_t)XML_GetCurrentByteIndex(s->parser);
        s->matched = 0;
        s->field_depth = s->subfield_depth = 0;
        return;
    }
    if (!s->record_depth || s->matched) return;
    if (s->depth == s->record_depth + 1 && marc_name(name, "controlfield")) {
        const char *t = attribute(atts, "tag");
        if (!s->subfield && t && strcmp(t, s->tag) == 0) s->matched = 1;
    } else if (s->depth == s->record_depth + 1 && marc_name(name, "datafield")) {
        const char *t = attribute(atts, "tag");
        s->field_depth = t && strcmp(t, s->tag) == 0 ? s->depth : 0;
        if (s->field_depth && !s->subfield) s->matched = 1;
    } else if (s->field_depth && s->subfield &&
               s->depth == s->record_depth + 2 && marc_name(name, "subfield")) {
        const char *code = attribute(atts, "code");
        if (code && strcmp(code, s->subfield) == 0) {
            s->subfield_depth = s->depth;
            s->value_len = 0;
        }
    }
}
static void XMLCALL character_data(void *userdata, const XML_Char *text, int len) {
    State *s = (State *)userdata;
    if (s->subfield_depth && !s->matched && s->equals &&
        !append_value(s, text, len)) stop(s, "out of memory collecting subfield value");
}
static void XMLCALL end_element(void *userdata, const char *name) {
    State *s = (State *)userdata;
    if (s->subfield_depth == s->depth && marc_name(name, "subfield")) {
        if (!s->equals || strcmp(s->value ? s->value : "", s->equals) == 0)
            s->matched = 1;
        s->subfield_depth = 0;
    }
    if (s->field_depth == s->depth && marc_name(name, "datafield")) s->field_depth = 0;
    if (s->record_depth == s->depth && marc_name(name, "record")) {
        if (s->matched) {
            if (s->size == s->capacity) {
                size_t cap = s->capacity ? s->capacity * 2 : 128;
                Hit *new_hits = realloc(s->hits, cap * sizeof(*new_hits));
                if (!new_hits) { stop(s, "out of memory storing offsets"); return; }
                s->hits = new_hits; s->capacity = cap;
            }
            int64_t end = (int64_t)XML_GetCurrentByteIndex(s->parser) +
                          (int64_t)XML_GetCurrentByteCount(s->parser);
            s->hits[s->size++] = (Hit){s->count, s->rec_start, end};
        }
        s->record_depth = 0;
        s->matched = 0;
    }
    s->depth--;
}
static void XMLCALL doctype(void *userdata, const XML_Char *a,
                           const XML_Char *b, const XML_Char *c, int d) {
    (void)a; (void)b; (void)c; (void)d;
    stop((State *)userdata, "DTD is unsupported for independent record extraction");
}
int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "Usage: record_offset_index FILE TAG SUBFIELD_OR_DASH EQUALS_OR_DASH\n");
        return 2;
    }
    if (strlen(argv[2]) != 3) { fprintf(stderr, "TAG must be 3 characters\n"); return 2; }
    State s = {0};
    s.tag = argv[2];
    s.subfield = strcmp(argv[3], "-") ? argv[3] : NULL;
    s.equals = strcmp(argv[4], "-") ? argv[4] : NULL;
    if (s.equals && !s.subfield) {fprintf(stderr, "EQUALS requires SUBFIELD\n");return 2;}
    FILE *f = fopen(argv[1], "rb");
    if (!f) {perror("opening XML"); return 2;}
    unsigned char head[256];
    size_t nh = fread(head, 1, sizeof(head), f);
    if ((nh >= 2 && ((head[0] == 0xff && head[1] == 0xfe) ||
                     (head[0] == 0xfe && head[1] == 0xff))) || memchr(head, 0, nh)) {
        fprintf(stderr, "Only UTF-8 input is supported\n"); fclose(f); return 2;
    }
    rewind(f);
    s.parser = XML_ParserCreateNS("UTF-8", '|');
    if (!s.parser) {fprintf(stderr, "Cannot allocate Expat parser\n");fclose(f);return 2;}
    XML_SetUserData(s.parser, &s);
    XML_SetElementHandler(s.parser, start_element, end_element);
    XML_SetCharacterDataHandler(s.parser, character_data);
    XML_SetStartDoctypeDeclHandler(s.parser, doctype);
    XML_SetParamEntityParsing(s.parser, XML_PARAM_ENTITY_PARSING_NEVER);
    unsigned char buf[65536];
    int failed = 0;
    for (;;) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (ferror(f)) {fprintf(stderr, "File read error\n");failed = 1;break;}
        int done = feof(f);
        if (XML_Parse(s.parser, (const char *)buf, (int)n, done) == XML_STATUS_ERROR) {
            fprintf(stderr, "Expat: %s at line %lu (byte %" PRId64 ")\n",
                    s.error ? s.error : XML_ErrorString(XML_GetErrorCode(s.parser)),
                    (unsigned long)XML_GetCurrentLineNumber(s.parser),
                    (int64_t)XML_GetCurrentByteIndex(s.parser));
            failed = 1; break;
        }
        if (done) break;
    }
    if (!failed) {
        printf("source_position\tstart_byte\tend_byte\n");
        for (size_t i = 0; i < s.size; ++i)
            printf("%zu\t%" PRId64 "\t%" PRId64 "\n",
                   s.hits[i].ordinal, s.hits[i].start, s.hits[i].end);
        fprintf(stderr, "Scanned %zu records; matched %zu\n", s.count, s.size);
    }
    XML_ParserFree(s.parser); fclose(f); free(s.hits); free(s.value);
    return failed ? 1 : 0;
}
