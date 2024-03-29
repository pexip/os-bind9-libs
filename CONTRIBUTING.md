<!--
 - Copyright (C) Internet Systems Consortium, Inc. ("ISC")
 -
 - This Source Code Form is subject to the terms of the Mozilla Public
 - License, v. 2.0. If a copy of the MPL was not distributed with this
 - file, You can obtain one at http://mozilla.org/MPL/2.0/.
 -
 - See the COPYRIGHT file distributed with this work for additional
 - information regarding copyright ownership.
-->
## BIND Source Access and Contributor Guidelines
*Feb 22, 2018*

### Contents

1. [Access to source code](#access)
1. [Reporting bugs](#bugs)
1. [Contributing code](#contrib)

### Introduction

Thank you for using BIND!

BIND is open source software that implements the Domain Name System (DNS)
protocols for the Internet. It is a reference implementation of those
protocols, but it is also production-grade software, suitable for use in
high-volume and high-reliability applications.  It is by far the most
widely used DNS software, providing a robust and stable platform on top of
which organizations can build distributed computing systems with the
knowledge that those systems are fully compliant with published DNS
standards.

BIND is and will always remain free and openly available.  It can be
used and modified in any way by anyone.

BIND is maintained by the [Internet Systems Consortium](https://www.isc.org),
a public-benefit 501(c)(3) nonprofit, using a "managed open source" approach:
anyone can see the source, but only ISC employees have commit access.
Until recently, the source could only be seen once ISC had published
a release: read access to the source repository was restricted just
as commit access was.  That's now changing, with the opening of a
public git mirror to the BIND source tree (see below).

### <a name="access"></a>Access to source code

Public BIND releases are always available from the
[ISC FTP site](ftp://ftp.isc.org/isc/bind9).

A public-access GIT repository is also available at
[https://gitlab.isc.org](https://gitlab.isc.org).
This repository is a mirror, updated several times per day, of the
source repository maintained by ISC.  It contains all the public release
branches; upcoming releases can be viewed in their current state at any
time.  It does *not* contain development branches or unreviewed work in
progress.  Commits which address security vulnerablilities are withheld
until after public disclosure.

You can browse the source online via
[https://gitlab.isc.org/isc-projects/bind9](https://gitlab.isc.org/isc-projects/bind9)

To clone the repository, use:

>       $ git clone https://gitlab.isc.org/isc-projects/bind9.git

Release branch names are of the form `v9_X`, where X represents the second
number in the BIND 9 version number.  So, to check out the BIND 9.12
branch, use:

>       $ git checkout v9_12

Whenever a branch is ready for publication, a tag will be placed of the
form `v9_X_Y`.  The 9.12.0 release, for instance, is tagged as `v9_12_0`.

The branch in which the next major release is being developed is called
`master`.

### <a name="bugs"></a>Reporting bugs

Reports of flaws in the BIND package, including software bugs, errors
in the documentation, missing files in the tarball, suggested changes
or requests for new features, etc, can be filed using
[https://gitlab.isc.org/isc-projects/bind9/issues](https://gitlab.isc.org/isc-projects/bind9/issues).

Due to a large ticket backlog, we are sometimes slow to respond,
especially if a bug is cosmetic or if a feature request is vague or
low in priority, but we will try at least to acknowledge legitimate
bug reports within a week.

ISC's ticketing system is publicly readable; however, you must have
an account to file a new issue. You can either register locally or
use credentials from an existing account at GitHub, GitLab, Google,
Twitter, or Facebook.

### Reporting possible security issues
If you think you may be seeing a potential security vulnerability in BIND
(for example, a crash with REQUIRE, INSIST, or ASSERT failure), please
report it immediately by emailing to security-officer@isc.org. Plain-text
e-mail is not a secure choice for communications concerning undisclosed
security issues so please encrypt your communications to us if possible,
using the [ISC Security Officer public key](https://www.isc.org/downloads/software-support-policy/openpgp-key/).

Do not discuss undisclosed security vulnerabilities on any public mailing list.
ISC has a long history of handling reported vulnerabilities promptly and
effectively and we respect and acknowledge responsible reporters.

ISC's Security Vulnerability Disclosure Policy is documented at [https://kb.isc.org/article/AA-00861/0](https://kb.isc.org/article/AA-00861/0).

If you have a crash, you may want to consult
[‘What to do if your BIND or DHCP server has crashed.’](https://kb.isc.org/article/AA-00340/89/What-to-do-if-your-BIND-or-DHCP-server-has-crashed.html)

### <a name="bugs"></a>Contributing code

BIND is licensed under the
[Mozilla Public License 2.0](http://www.isc.org/downloads/software-support-policy/isc-license/).
Earier versions (BIND 9.10 and earlier) were licensed under the [ISC License](http://www.isc.org/downloads/software-support-policy/isc-license/)

ISC does not require an explicit copyright assignment for patch
contributions.  However, by submitting a patch to ISC, you implicitly
certify that you are the author of the code, that you intend to reliquish
exclusive copyright, and that you grant permission to publish your work
under the open source license used for the BIND version(s) to which your
patch will be applied.

#### <a name="bind"></a>BIND code

Patches for BIND may be submitted directly via merge requests in
[ISC's Gitlab](https://gitlab.isc.org/isc-projects/bind9/) source
repository for BIND.

Patches can also be submitted as diffs against a specific version of
BIND -- preferably the current top of the `master` branch.  Diffs may
be generated using either `git format-patch` or `git diff`.

Those wanting to write code for BIND may be interested in the
[developer information](doc/dev/dev.md) page, which includes information
about BIND design and coding practices, including discussion of internal
APIs and overall system architecture.  (This is a work in progress, and
still quite preliminary.)

Every patch submitted will be reviewed by ISC engineers following our
[code review process](doc/dev/dev.md#reviews) before it is merged.

It may take considerable time to review patch submissions, especially if
they don't meet ISC style and quality guidelines.  If a patch is a good
idea, we can and will do additional work to bring it up to par, but if
we're busy with other work, it may take us a long time to get to it.

To ensure your patch is acted on as promptly as possible, please:

* Try to adhere to the [BIND 9 coding style](doc/dev/style.md).
* Run `make` `check` to ensure your change hasn't caused any
  functional regressions.
* Document your work, both in the patch itself and in the
  accompanying email.
* In patches that make non-trivial functional changes, include system
  tests if possible; when introducing or substantially altering a
  library API, include unit tests. See [Testing](doc/dev/dev.md#testing)
  for more information.

##### Changes to `configure`

If you need to make changes to `configure`, you should not edit it
directly; instead, edit `configure.in`, then run `autoconf`.  Similarly,
instead of editing `config.h.in` directly, edit `configure.in` and run
`autoheader`.

When submitting a patch as a diff, it's fine to omit the `configure`
diffs to save space.  Just send the `configure.in` diffs and we'll
generate the new `configure` during the review process.

##### Documentation

All functional changes should be documented. There are three types
of documentation in the BIND source tree:

* Man pages are kept alongside the source code for the commands
  they document, in files ending in `.docbook`; for example, the
  `named` man page is `bin/named/named.docbook`.
* The *BIND 9 Administrator Reference Manual* is mostly in
  `doc/arm/Bv9ARM-book.xml`, plus a few other XML files that are included
  in it.
* API documentation is in the header file describing the API, in
  Doxygen-formatted comments.

It is not necessary to edit any documentation files other than these;
all PDF, HTML, and `nroff`-format man page files will be updated
automatically from the `docbook` and `XML` files after merging.

Patches to improve existing documentation are also very welcome!

##### Tests

BIND is a large and complex project. We rely heavily on continuous
automated testing and cannot merge new code without adequate test coverage.
Please see [the 'Testing' section of doc/dev/dev.md](doc/dev/dev.md#testing)
for more information.

#### Thanks

Thank you for your interest in contributing to the ongoing development
of BIND.
