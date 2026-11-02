# Third-party notices

AL-Go4ADO is a wrapper around [AL-Go for GitHub](https://github.com/microsoft/AL-Go) by Microsoft.
It is not affiliated with or endorsed by Microsoft.

## AL-Go for GitHub

Source: https://github.com/microsoft/AL-Go (actions: https://github.com/microsoft/AL-Go-Actions)

AL-Go4ADO contains material derived from AL-Go for GitHub:

- `samples/per-tenant-extension/.AL-Go/settings.json`, `samples/per-tenant-extension/.github/*.settings.json`
  and `samples/per-tenant-extension/.gitignore` are copied from the AL-Go Per Tenant Extension template.
- Functions in `src/AlGoAdo.Overrides.ps1` (for example `GetDependencies`, `GetLatestRelease`,
  `CloneIntoNewFolder`, `CommitFromNewFolder`) are adapted from `Actions/AL-Go-Helper.ps1` and
  `Actions/Github-Helper.psm1` and keep their signatures and parts of their logic.

The AL-Go actions themselves are not part of this repository; they are downloaded at run time
(`src/Initialize-AlGoAdo.ps1`) and stay under their own license.

```
MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE
```
