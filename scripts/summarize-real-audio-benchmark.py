#!/usr/bin/env python3
"""Report assembly differences from native final results (not acoustic accuracy)."""
import difflib
import json
import re
import sys
from pathlib import Path


def words(text):
    return re.findall(r"\b[\w']+\b", text.lower())


def summarize(prefix):
    events = json.loads(Path(prefix + '-events.json').read_text())
    sentences = json.loads(Path(prefix + '-transcript.json').read_text())
    final = [event['text'].strip() for event in events if event['isFinal'] and event['text'].strip()]
    actual = [sentence['text'] for sentence in sentences]
    reference_words = words(' '.join(final))
    saved_words = words(' '.join(actual))
    matcher = difflib.SequenceMatcher(None, reference_words, saved_words, autojunk=False)
    added = removed = 0
    for tag, i, j, a, b in matcher.get_opcodes():
        if tag != 'equal':
            added += b - a
            removed += j - i
    summary = {
        'prefix': prefix,
        'result_count': len(events),
        'native_final_lines': len(final),
        'saved_lines': len(actual),
        'native_final_words': len(reference_words),
        'saved_words': len(saved_words),
        'words_added_vs_native_final': added,
        'words_removed_vs_native_final': removed,
        'saved_lines_equal_native_final': actual == final,
        'first_result_seconds': events[0]['receivedAt'] if events else None,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    for line in difflib.unified_diff(final, actual, fromfile='native final', tofile='saved', lineterm=''):
        print(line)


if __name__ == '__main__':
    for prefix in sys.argv[1:]:
        summarize(prefix)
