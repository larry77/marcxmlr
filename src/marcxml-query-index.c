/* Experimental C4 MARC query screening.
 * One namespace-aware Expat pass per XML file; retain offsets only.
 * Independent of the legacy C4 scanner and unfiltered code paths.
 * Only the existing C4 materializer converts selected records to rows.
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

typedef struct { int position; double start, end; } QueryHit;
typedef struct {
    const char *tag, *subfield, *equals, *contains, *ind1, *ind2;
} QueryPredicate;

typedef struct {
    XML_Parser parser;
    QueryPredicate *predicates;
    int n_predicates, *program, n_program;
    unsigned char *matched, *field_ok, *candidate, *stack;
    int depth, record_depth, field_depth, text_depth;
    int root_record, root_collection, record_count;
    double record_start;
    QueryHit *hits;
    size_t n_hits, hit_capacity;
    char *value;
    size_t value_length, value_capacity;
    const char *error;
} QueryState;

static int query_name_is(const char *name, const char *local) {
    const char *sep = strchr(name, '|');
    if (!sep) return strcmp(name, local) == 0;
    return (size_t)(sep - name) == strlen(MARC_NS) &&
           strncmp(name, MARC_NS, sep - name) == 0 &&
           strcmp(sep + 1, local) == 0;
}
static const char *query_attribute(const XML_Char **attrs, const char *key) {
    for (size_t i = 0; attrs[i]; i += 2)
        if (strcmp(attrs[i], key) == 0) return attrs[i + 1];
    return NULL;
}
static int query_equal(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}
static void query_fail(QueryState *s, const char *message) {
    s->error = message;
    XML_StopParser(s->parser, XML_FALSE);
}
static int query_append(QueryState *s, const char *text, size_t size) {
    if (size > SIZE_MAX - s->value_length - 1) return 0;
    size_t needed = s->value_length + size + 1;
    if (needed > s->value_capacity) {
        size_t next = s->value_capacity ? s->value_capacity : 128;
        while (next < needed) {
            if (next > SIZE_MAX / 2) return 0;
            next *= 2;
        }
        char *buffer = realloc(s->value, next);
        if (!buffer) return 0;
        s->value = buffer;
        s->value_capacity = next;
    }
    memcpy(s->value + s->value_length, text, size);
    s->value_length += size;
    s->value[s->value_length] = '\0';
    return 1;
}
static int query_value_matches(const QueryPredicate *p, const char *value) {
    if (p->equals && strcmp(p->equals, value) != 0) return 0;
    if (p->contains && !strstr(value, p->contains)) return 0;
    return 1;
}
static int query_eval(QueryState *s) {
    int top = 0;
    for (int i = 0; i < s->n_program; ++i) {
        int op = s->program[i];
        if (op > 0) {
            s->stack[top++] = s->matched[op - 1];
        } else if (op == -3) {
            s->stack[top - 1] = !s->stack[top - 1];
        } else {
            unsigned char right = s->stack[--top];
            if (op == -1) s->stack[top - 1] &= right;
            else s->stack[top - 1] |= right;
        }
    }
    return s->stack[0] != 0;
}
static int query_store_hit(QueryState *s, double end) {
    if (s->n_hits == s->hit_capacity) {
        size_t next = s->hit_capacity ? s->hit_capacity * 2 : 128;
        if (next < s->hit_capacity || next > SIZE_MAX / sizeof(QueryHit))
            return 0;
        QueryHit *hits = realloc(s->hits, next * sizeof(QueryHit));
        if (!hits) return 0;
        s->hits = hits;
        s->hit_capacity = next;
    }
    s->hits[s->n_hits++] = (QueryHit){s->record_count, s->record_start, end};
    return 1;
}
static void query_start_text(QueryState *s, int depth) {
    s->value_length = 0;
    s->text_depth = depth;
}
static void XMLCALL query_start(void *context, const XML_Char *name,
                                const XML_Char **attrs) {
    QueryState *s = context;
    ++s->depth;
    if (s->depth == 1) {
        s->root_record = query_name_is(name, "record");
        s->root_collection = query_name_is(name, "collection");
        if (!s->root_record && !s->root_collection)
            query_fail(s, "root must be MARCXML collection or record");
    }
    if (s->root_collection && s->depth == 2 &&
        !query_name_is(name, "record")) {
        query_fail(s, "collection may contain only MARCXML records");
        return;
    }
    if ((s->root_record && s->depth == 1) ||
        (s->root_collection && s->depth == 2 &&
         query_name_is(name, "record"))) {
        if (s->record_count == INT_MAX) {
            query_fail(s, "source contains too many records");
            return;
        }
        ++s->record_count;
        s->record_depth = s->depth;
        s->record_start = (double)MARCXMLR_EXPAT_BYTE_INDEX(s->parser);
        memset(s->matched, 0, (size_t)s->n_predicates);
        s->field_depth = s->text_depth = 0;
        return;
    }
    if (!s->record_depth) return;

    if (s->depth == s->record_depth + 1 &&
        (query_name_is(name, "leader") ||
         query_name_is(name, "controlfield"))) {
        const char *tag = query_name_is(name, "leader") ? "LDR" :
                          query_attribute(attrs, "tag");
        int needs_text = 0;
        memset(s->candidate, 0, (size_t)s->n_predicates);
        for (int i = 0; i < s->n_predicates; ++i) {
            QueryPredicate *p = &s->predicates[i];
            if (s->matched[i] || !query_equal(p->tag, tag) ||
                p->subfield || p->ind1 || p->ind2) continue;
            if (p->equals || p->contains) {
                s->candidate[i] = 1;
                needs_text = 1;
            } else s->matched[i] = 1;
        }
        if (needs_text) query_start_text(s, s->depth);
        return;
    }
    if (s->depth == s->record_depth + 1 &&
        query_name_is(name, "datafield")) {
        const char *tag = query_attribute(attrs, "tag");
        const char *ind1 = query_attribute(attrs, "ind1");
        const char *ind2 = query_attribute(attrs, "ind2");
        s->field_depth = s->depth;
        for (int i = 0; i < s->n_predicates; ++i) {
            QueryPredicate *p = &s->predicates[i];
            s->field_ok[i] = !s->matched[i] && query_equal(p->tag, tag) &&
                (!p->ind1 || query_equal(p->ind1, ind1)) &&
                (!p->ind2 || query_equal(p->ind2, ind2));
        }
        return;
    }
    if (s->field_depth && s->depth == s->field_depth + 1 &&
        query_name_is(name, "subfield")) {
        const char *code = query_attribute(attrs, "code");
        int needs_text = 0;
        memset(s->candidate, 0, (size_t)s->n_predicates);
        for (int i = 0; i < s->n_predicates; ++i) {
            QueryPredicate *p = &s->predicates[i];
            if (!s->field_ok[i] || s->matched[i] ||
                (p->subfield && !query_equal(p->subfield, code))) continue;
            if (p->equals || p->contains) {
                s->candidate[i] = 1;
                needs_text = 1;
            } else s->matched[i] = 1;
        }
        if (needs_text) query_start_text(s, s->depth);
    }
}
static void XMLCALL query_characters(void *context, const XML_Char *text,
                                     int length) {
    QueryState *s = context;
    if (s->text_depth && !query_append(s, text, (size_t)length))
        query_fail(s, "out of memory collecting MARC field value");
}
static void XMLCALL query_end(void *context, const XML_Char *name) {
    QueryState *s = context;
    if (s->text_depth == s->depth) {
        const char *value = s->value_length ? s->value : "";
        for (int i = 0; i < s->n_predicates; ++i)
            if (s->candidate[i] && query_value_matches(&s->predicates[i], value))
                s->matched[i] = 1;
        s->text_depth = 0;
    }
    if (s->field_depth == s->depth && query_name_is(name, "datafield"))
        s->field_depth = 0;
    if (s->record_depth == s->depth && query_name_is(name, "record")) {
        if (query_eval(s) && !query_store_hit(s,
               (double)MARCXMLR_EXPAT_BYTE_INDEX(s->parser) +
               (double)MARCXMLR_EXPAT_BYTE_COUNT(s->parser))) {
            query_fail(s, "out of memory storing selected record offsets");
            return;
        }
        s->record_depth = 0;
    }
    --s->depth;
}
static void XMLCALL query_reject_dtd(void *context, const XML_Char *a,
                                     const XML_Char *b, const XML_Char *c, int d) {
    (void)a; (void)b; (void)c; (void)d;
    query_fail(context, "DTD is unsupported for independent record extraction");
}
static const char *query_optional(SEXP column, int i) {
    SEXP value = STRING_ELT(column, i);
    return value == NA_STRING ? NULL : CHAR(value);
}
static SEXP query_column(SEXP spec, const char *name, int *n) {
    SEXP keys = Rf_getAttrib(spec, R_NamesSymbol);
    for (R_xlen_t i = 0; i < XLENGTH(spec); ++i)
        if (strcmp(CHAR(STRING_ELT(keys, i)), name) == 0) {
            SEXP col = VECTOR_ELT(spec, i);
            if (TYPEOF(col) != STRSXP || XLENGTH(col) != *n)
                Rf_error("Malformed native MARC query predicates.");
            return col;
        }
    Rf_error("Missing native MARC query predicate column: %s", name);
    return R_NilValue;
}
static void query_free(QueryState *s) {
    free(s->predicates); free(s->matched); free(s->field_ok);
    free(s->candidate); free(s->stack); free(s->program);
    free(s->hits); free(s->value);
}
#endif

SEXP attribute_visible C_marcxml_query_offset_index(SEXP path, SEXP predicates,
                                                    SEXP program) {
#ifndef MARCXMLR_HAS_EXPAT
    (void)path; (void)predicates; (void)program;
    Rf_error("MARC query screening requires Expat support at package build time.");
    return R_NilValue;
#else
    if (TYPEOF(path) != STRSXP || XLENGTH(path) != 1 ||
        STRING_ELT(path, 0) == NA_STRING || TYPEOF(predicates) != VECSXP ||
        TYPEOF(program) != INTSXP || XLENGTH(program) < 1 ||
        XLENGTH(program) > INT_MAX)
        Rf_error("Invalid native MARC query arguments.");
    SEXP names = Rf_getAttrib(predicates, R_NamesSymbol);
    if (TYPEOF(names) != STRSXP || XLENGTH(names) != XLENGTH(predicates))
        Rf_error("Native MARC query predicates must be named.");
    int n = -1;
    for (R_xlen_t i = 0; i < XLENGTH(predicates); ++i) {
        SEXP col = VECTOR_ELT(predicates, i);
        if (TYPEOF(col) != STRSXP || XLENGTH(col) > INT_MAX)
            Rf_error("Malformed native MARC query predicate column.");
        if (n < 0) n = (int)XLENGTH(col);
        if ((int)XLENGTH(col) != n)
            Rf_error("Native MARC query predicate columns have unequal lengths.");
    }
    if (n < 1 || n > INT_MAX / 2) Rf_error("Invalid predicate count.");
    SEXP tags = query_column(predicates, "tag", &n);
    SEXP subfields = query_column(predicates, "subfield", &n);
    SEXP equals = query_column(predicates, "equals", &n);
    SEXP contains = query_column(predicates, "contains", &n);
    SEXP ind1 = query_column(predicates, "ind1", &n);
    SEXP ind2 = query_column(predicates, "ind2", &n);
    QueryState s = {0};
    s.n_predicates = n;
    s.n_program = (int)XLENGTH(program);
    s.predicates = calloc((size_t)n, sizeof(QueryPredicate));
    s.matched = calloc((size_t)n, 1);
    s.field_ok = calloc((size_t)n, 1);
    s.candidate = calloc((size_t)n, 1);
    s.stack = calloc((size_t)s.n_program, 1);
    s.program = malloc((size_t)s.n_program * sizeof(int));
    if (!s.predicates || !s.matched || !s.field_ok || !s.candidate ||
        !s.stack || !s.program) {
        query_free(&s);
        Rf_error("Out of memory compiling MARC query.");
    }
    for (int i = 0; i < n; ++i) {
        QueryPredicate *p = &s.predicates[i];
        p->tag = query_optional(tags, i);
        p->subfield = query_optional(subfields, i);
        p->equals = query_optional(equals, i);
        p->contains = query_optional(contains, i);
        p->ind1 = query_optional(ind1, i);
        p->ind2 = query_optional(ind2, i);
        if (!p->tag || (p->equals && p->contains)) {
            query_free(&s);
            Rf_error("Malformed MARC query predicate.");
        }
    }
    /* Validate postfix expression once, not for each XML record. */
    int depth = 0;
    for (int i = 0; i < s.n_program; ++i) {
        int op = INTEGER(program)[i];
        s.program[i] = op;
        if (op > 0 && op <= n) ++depth;
        else if (op == -3 && depth >= 1) { /* NOT */ }
        else if ((op == -1 || op == -2) && depth >= 2) --depth;
        else {
            query_free(&s);
            Rf_error("Malformed MARC query Boolean program.");
        }
    }
    if (depth != 1) {
        query_free(&s);
        Rf_error("Malformed MARC query Boolean program.");
    }
    const char *filename = CHAR(STRING_ELT(path, 0));
    FILE *file = fopen(filename, "rb");
    if (!file) {
        query_free(&s);
        Rf_error("Cannot open MARCXML for query screening: %s", filename);
    }
    unsigned char header[512];
    size_t length = fread(header, 1, sizeof(header), file);
    int unsupported = (length >= 2 &&
        ((header[0] == 0xff && header[1] == 0xfe) ||
         (header[0] == 0xfe && header[1] == 0xff) ||
         (header[0] == 0x1f && header[1] == 0x8b))) ||
         memchr(header, 0, length) != NULL;
    if (unsupported) {
        fclose(file); query_free(&s);
        Rf_error("Query screening requires uncompressed UTF-8 MARCXML.");
    }
    rewind(file);
    s.parser = XML_ParserCreateNS("UTF-8", '|');
    if (!s.parser) {
        fclose(file); query_free(&s);
        Rf_error("Cannot initialize Expat MARC query parser.");
    }
    XML_SetUserData(s.parser, &s);
    XML_SetElementHandler(s.parser, query_start, query_end);
    XML_SetCharacterDataHandler(s.parser, query_characters);
    XML_SetStartDoctypeDeclHandler(s.parser, query_reject_dtd);
    XML_SetParamEntityParsing(s.parser, XML_PARAM_ENTITY_PARSING_NEVER);
    char buffer[65536], error_message[512] = {0};
    int failed = 0;
    for (;;) {
        size_t count = fread(buffer, 1, sizeof(buffer), file);
        if (ferror(file)) {
            snprintf(error_message, sizeof(error_message), "Cannot read MARCXML input.");
            failed = 1; break;
        }
        int final = feof(file);
        if (XML_Parse(s.parser, buffer, (int)count, final) == XML_STATUS_ERROR) {
            snprintf(error_message, sizeof(error_message),
                     "Expat MARC query screening: %s at line %lu",
                     s.error ? s.error : XML_ErrorString(XML_GetErrorCode(s.parser)),
                     (unsigned long)MARCXMLR_EXPAT_LINE_NUMBER(s.parser));
            failed = 1; break;
        }
        if (final) break;
    }
    XML_ParserFree(s.parser);
    fclose(file);
    if (failed) {
        query_free(&s);
        Rf_error("%s", error_message);
    }
    SEXP answer = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP positions = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)s.n_hits));
    SEXP starts = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)s.n_hits));
    SEXP ends = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)s.n_hits));
    for (size_t i = 0; i < s.n_hits; ++i) {
        INTEGER(positions)[i] = s.hits[i].position;
        REAL(starts)[i] = s.hits[i].start;
        REAL(ends)[i] = s.hits[i].end;
    }
    SET_VECTOR_ELT(answer, 0, positions);
    SET_VECTOR_ELT(answer, 1, starts);
    SET_VECTOR_ELT(answer, 2, ends);
    SEXP colnames = PROTECT(Rf_allocVector(STRSXP, 3));
    SET_STRING_ELT(colnames, 0, Rf_mkChar("source_position"));
    SET_STRING_ELT(colnames, 1, Rf_mkChar("start_byte"));
    SET_STRING_ELT(colnames, 2, Rf_mkChar("end_byte"));
    Rf_setAttrib(answer, R_NamesSymbol, colnames);
    query_free(&s);
    UNPROTECT(5);
    return answer;
#endif
}
