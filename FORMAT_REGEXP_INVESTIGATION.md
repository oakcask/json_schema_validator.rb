# Format Parser Regexp Investigation

## Decision

Keep the current hand-written format parsers.

Ruby regular expressions improve interpreter performance for the tested inputs,
but the result is mixed under YJIT. More importantly, the existing parsers are
allocation-conscious, single-pass implementations whose structure is suitable
for the planned native evaluator. Replacing them now would introduce a
Ruby-specific intermediate design that would later be replaced again.

## Baseline and Method

The baseline was `origin/main` at `06c8d78` using Ruby 4.0.6 on x86-64 Linux.

Candidate implementations used precompiled regular expressions and
`Regexp#match?`. Calendar-day validation and leap-second validation remained
small numeric checks because expressing those rules entirely in a regular
expression would make the implementation less maintainable.

Each implementation validated all string inputs for its format from the Draft
2020-12 optional format suite. The table reports candidate throughput divided
by baseline throughput, so values above 1.0 favor the regexp candidate.

| Format | Interpreter | YJIT |
| --- | ---: | ---: |
| `date` | 1.87x | 1.52x |
| `time` | 3.53x | 3.00x |
| `date-time` | 3.27x | 2.69x |
| `duration` | 1.41x | 0.68x |
| `ipv4` | 4.12x | 2.21x |
| `json-pointer` | 1.49x | 0.30x |
| `relative-json-pointer` | 1.80x | 0.88x |
| `uuid` | 9.23x | 4.47x |

The regexp candidates allocated no objects per validation in this benchmark.
The current implementations also allocated no objects except for `ipv4`
(0.8571 objects per validation) and `uuid` (0.1818 objects per validation) on
the official input mix.

## Correctness and Pathological Inputs

The candidates agreed with the current implementation for every official
input and for 20,000 deterministic randomized strings per format (160,000
randomized inputs total). The existing format specs also passed.

Regular expressions for duration and JSON Pointer variants were checked with
100 KB invalid inputs. Their runtime remained linear in this check, with no
sign of catastrophic backtracking.

Ruby regular expressions raise `ArgumentError` for strings containing invalid
byte sequences in their declared encoding. The byte-oriented parsers do not
necessarily reject or raise for the same values. JSON text cannot contain such
strings, but direct Ruby API callers can construct them, so adopting regexp
validation would require an explicit compatibility decision.

## Rationale

The interpreter-only result makes replacing every parser look attractive, but
YJIT demonstrates that the simple Ruby loops can already optimize well:
duration and both JSON Pointer formats lose performance after regexp
conversion. The strongest consistently positive candidates are UUID, IPv4,
and the date/time formats, but changing only those still creates migration and
compatibility work for code expected to move into the native evaluator.

The measured gains therefore do not justify changing the implementation
shape before that migration. These results can be revisited if native evaluator
work is postponed or Ruby-level format validation remains a long-term path.
