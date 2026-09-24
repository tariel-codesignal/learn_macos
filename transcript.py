#!/usr/bin/env python3
"""Turn the raw session log (`script -f` output) into the plain transcript the
grader reads.

Stripping escape sequences out of the log is not enough: zsh's line editor
moves the cursor and redraws. A pasted command is drawn highlighted, then the
cursor steps back (ESC[17D) and the same text is drawn again plain - with the
movement deleted, the two copies run together ("cd xcd x"). Every prompt also
starts with a CR. So the log is replayed through a small line-based terminal
instead, and the transcript is what the screen showed.

The terminal never wraps: its width isn't in the log, and a long command reads
better on one line anyway. Clearing the screen keeps what came before, so the
grader still sees commands run before a `clear`.

    python3 transcript.py /tmp/.session_log.txt
"""
import re
import sys
import unicodedata

PROMPT = re.compile(r'Learner@Learners-MacBook-Pro [^ ]* % ')
ESCAPE = re.compile(r'\x1b\[[0-9;?>=]*[ -/]*[@-~]|\r')


class Screen:
    def __init__(self):
        self.lines = [[]]
        self.row = 0
        self.col = 0

    def _line(self):
        while self.row >= len(self.lines):
            self.lines.append([])
        line = self.lines[self.row]
        if len(line) < self.col:
            line.extend(' ' * (self.col - len(line)))
        return line

    def put(self, ch):
        wide = unicodedata.east_asian_width(ch) in 'WF'
        line = self._line()
        cells = [ch, ''] if wide else [ch]  # '' is the right half of a wide char
        line[self.col:self.col + len(cells)] = cells
        self.col += len(cells)

    def newline(self):
        # always back to column 0: the tty turns output \n into \r\n anyway,
        # and script's own header ends in a bare \n
        self.row += 1
        self.col = 0
        self._line()

    def csi(self, params, final):
        nums = [int(p) if p.isdigit() else 0 for p in params.lstrip('?>=').split(';')] if params else []
        n = nums[0] if nums and nums[0] else 1
        mode = nums[0] if nums else 0
        line = self._line()
        if final == 'C':
            self.col += n
        elif final == 'D':
            self.col = max(0, self.col - n)
        elif final == 'G':
            self.col = n - 1
        elif final == 'A':
            self.row = max(0, self.row - n)
        elif final == 'B':
            self.row += n
            self._line()
        elif final in 'Hf':
            # Absolute rows mean nothing without a screen size. A move home is
            # what `clear` sends: start on a fresh line instead.
            if any(self.lines[self.row]):
                self.newline()
            self.col = (nums[1] - 1) if len(nums) > 1 and nums[1] else 0
        elif final == 'K':
            if mode == 0:
                del line[self.col:]
            elif mode == 1:
                line[:self.col + 1] = ' ' * min(len(line), self.col + 1)
            else:
                del line[:]
        elif final == 'J':
            if mode == 0:
                del line[self.col:]
                del self.lines[self.row + 1:]
        elif final == 'P':
            del line[self.col:self.col + n]
        elif final == '@':
            line[self.col:self.col] = ' ' * n
        elif final == 'X':
            end = min(len(line), self.col + n)
            line[self.col:end] = ' ' * (end - self.col)
        # everything else (colours, modes, scroll regions) draws nothing

    def text(self):
        return [''.join(l).rstrip() for l in self.lines]


def render(data):
    s = Screen()
    i, n = 0, len(data)
    while i < n:
        ch = data[i]
        if ch == '\x1b':
            nxt = data[i + 1] if i + 1 < n else ''
            if nxt == '[':
                m = re.compile(r'\[([0-9;?>=]*)[ -/]*([@-~])').match(data, i + 1)
                if m:
                    s.csi(m.group(1), m.group(2))
                    i = m.end()
                    continue
                i += 2
            elif nxt == ']':  # OSC, ends at BEL or ESC \
                end = len(data)
                for term in ('\x07', '\x1b\\'):
                    j = data.find(term, i + 2)
                    if j != -1 and j < end:
                        end = j + len(term)
                i = end
            elif nxt in '()*+#%':  # charset designation: one more byte
                i += 3
            else:
                i += 2
            continue
        if ch == '\r':
            # Output that ends without a newline is on screen only until the
            # next prompt's CR draws over it (PROMPT_SP is off). Keep it on its
            # own line; a CR that redraws a prompt line is just a CR.
            j = i + 1
            while True:
                m = ESCAPE.match(data, j)
                if not m:
                    break
                j = m.end()
            here = ''.join(s._line()).strip()
            if here and not PROMPT.match(here) and PROMPT.match(data, j):
                s.newline()
            s.col = 0
        elif ch == '\n':
            s.newline()
        elif ch == '\b':
            s.col = max(0, s.col - 1)
        elif ch == '\t':
            s.col = (s.col // 8 + 1) * 8
        elif ch >= ' ' and ch != '\x7f':
            s.put(ch)
        i += 1
    return s.text()


def transcript(lines):
    out = []
    for line in lines:
        if line.startswith(('Script started on', 'Script done on')):
            continue
        # output without a trailing newline leaves the next prompt on its line
        line = PROMPT.sub(lambda m: ('\n' if m.start() else '') + m.group(0), line)
        out.extend(line.split('\n'))
    kept, blank = [], False
    for line in out:
        if PROMPT.fullmatch(line + ' ') or PROMPT.fullmatch(line):
            continue  # a prompt with nothing typed
        if re.fullmatch(r'%\s*', line):
            continue  # zsh's partial-line marker
        if not line.strip():
            blank = True
            continue
        # blank lines inside real output are kept; a run before a prompt is
        # just the line editor
        if blank and kept and not PROMPT.match(line):
            kept.append('')
        blank = False
        kept.append(line)
    return kept


def main():
    with open(sys.argv[1], 'rb') as f:
        data = f.read().decode('utf-8', 'replace')
    for line in transcript(render(data)):
        print(line)


if __name__ == '__main__':
    main()
