/* Use Expat 2.9+ 64-bit location APIs when available.
 * Keep compatibility with older Expat versions supported by marcxmlr.
 * Include this header only after <expat.h>.
 */
#ifndef MARCXMLR_EXPAT_COMPAT_H
#define MARCXMLR_EXPAT_COMPAT_H

#if (XML_MAJOR_VERSION > 2) || (XML_MAJOR_VERSION == 2 && XML_MINOR_VERSION >= 9)
# define MARCXMLR_EXPAT_BYTE_INDEX XML_GetCurrentByteIndex64
# define MARCXMLR_EXPAT_BYTE_COUNT XML_GetCurrentByteCount64
# define MARCXMLR_EXPAT_LINE_NUMBER XML_GetCurrentLineNumber64
#else
# define MARCXMLR_EXPAT_BYTE_INDEX XML_GetCurrentByteIndex
# define MARCXMLR_EXPAT_BYTE_COUNT XML_GetCurrentByteCount
# define MARCXMLR_EXPAT_LINE_NUMBER XML_GetCurrentLineNumber
#endif

#endif /* MARCXMLR_EXPAT_COMPAT_H */
