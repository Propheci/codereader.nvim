# codereader.nvim

A Neovim plugin that helps one reader understand a large, unfamiliar codebase. The reader records their path through the code and writes short notes about what they find.

## Language

### Reading

**Reader**:
The person who reads the codebase and writes the notes. There is one Reader for each set of notes.
_Avoid_: User, author

**Project**:
The codebase that a set of Notes and Trails belongs to.
_Avoid_: Workspace, repo

**Trail**:
An ordered record of the code locations that the Reader visited while following the code.
_Avoid_: History, breadcrumbs, path

**Stop**:
One code location on a Trail.
_Avoid_: Step, entry, node

**Lost**:
Describes a Stop whose code location can no longer be found. Unlike an Orphan, it holds nothing the Reader wrote.
_Avoid_: Broken, missing

### Notes

**Note**:
A short text that the Reader writes about the code, to refer to later.
_Avoid_: Comment, annotation, memo

**Anchor**:
The thing in the Project that a Note is attached to. Each Note has exactly one Anchor.
_Avoid_: Location, target, mark

**Range Anchor**:
An Anchor on a range of lines in one file.

**Symbol Anchor**:
An Anchor on a named code symbol, for example a function or a class.

**File Anchor**:
An Anchor on a whole file.

**Project Anchor**:
An Anchor on the Project as a whole, for Notes that have no single code location.

**Drift**:
The change in the code under an Anchor after the Note was written, for example lines that moved or were edited.
_Avoid_: Stale, outdated

**Drifted**:
Describes a Note whose anchored code changed after the Reader wrote or last confirmed it. The Note may now be wrong.
_Avoid_: Stale, outdated

**Orphan**:
A Note whose Anchor can no longer be found in the Project. The Note is kept until the Reader attaches it again or deletes it.
_Avoid_: Lost note, dangling note, broken note
