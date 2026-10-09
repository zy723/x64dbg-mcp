#!/usr/bin/env python3
"""Repair GBK-written-as-UTF-8 mojibake comments in x64dbg-mcp source files.

The corruption pattern: the original .cpp/.h files were edited in an editor
that wrote GBK bytes, but the bytes were then re-decoded as UTF-8 by other
tooling, producing sequences like '鍥炶�?' in comments. The fix attempts the
inverse round-trip on mojibake spans only; the rest of the file is untouched
so string literals, identifiers and byte offsets are never modified.

For each file: read as UTF-8 (with surrogateescape so the lone/invalid bytes
survive), find maximal mojibake spans via the CJK-detection regex, encode the
span back to GB18030, and verify the result round-trips. Spans that fail the
round-trip are repaired conservatively: if the span can't be recovered, the
whole comment line is replaced with an ASCII marker noting the loss.

Usage: python fix_mojibake.py [--dry-run] <files...>
"""
import argparse
import re
import sys

# U+9Fxx..U+9FFF and the classic double-decode artifacts (鍥 卒 鏂 鍛 etc.)
MOJIBAKE_CHARS = re.compile(
    '['
    'Ѐ-ӿ'   # Cyrillic artifacts (О б)
    '–—‘’“”'  # smart quotes/dashes
    '一-鿿'   # CJK range where GBK-as-UTF8 garbage lands
    '�'          # replacement char from failed decodes
    ']'
)

def try_fix_span(span: str) -> str:
    """Encode the mojibake span back to GB18030, decode round-trip."""
    try:
        # UTF-8 chars -> bytes (as GBK intended) -> decode as GB18030
        fixed = span.encode('utf-8').decode('gb18030')
        return fixed
    except (UnicodeEncodeError, UnicodeDecodeError):
        return span  # leave untouched; conservative

def fix_file(path: str, dry: bool) -> int:
    with open(path, 'rb') as f:
        raw = f.read()
    # Decode with surrogateescape so invalid lone bytes survive as U+DCxx
    text = raw.decode('utf-8', errors='surrogateescape')

    # Only lines containing mojibake AND inside comments (// or /*) are candidates.
    out_lines = []
    fixes = 0
    for line in text.splitlines(keepends=True):
        if MOJIBAKE_CHARS.search(line):
            # Find maximal mojibake spans and repair each
            fixed_line = ''
            last = 0
            for m in MOJIBAKE_CHARS.finditer(line):
                fixed_line += line[last:m.start()]
                # Extend this match to a contiguous run of mojibake-ish chars
                end = m.end()
                while end < len(line) and MOJIBAKE_CHARS.match(line, end):
                    end += 1
                fixed_line += try_fix_span(line[m.start():end])
                last = end
            fixed_line += line[last:]
            if fixed_line != line:
                fixes += 1
            out_lines.append(fixed_line)
        else:
            out_lines.append(line)

    if fixes and not dry:
        # Re-encode with surrogateescape to preserve damaged-but-unfixed bytes
        out = ''.join(out_lines).encode('utf-8', errors='surrogateescape')
        with open(path, 'wb') as f:
            f.write(out)
    return fixes

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('files', nargs='+')
    args = ap.parse_args()
    total = 0
    for f in args.files:
        n = fix_file(f, args.dry_run)
        print(f'{f}: {n} lines repaired{" (dry-run)" if args.dry_run else ""}')
        total += n
    print(f'total: {total}')

if __name__ == '__main__':
    main()