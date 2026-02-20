# Open-Core Licensing Research for Synaptic Assistant

## Executive Summary

This document evaluates licensing options for Synaptic Assistant as an open-core product: an open-source AI assistant desktop app with a paid cloud/SaaS tier. The goal is to find a license that (1) allows community use, modification, and contribution, (2) protects the commercial cloud offering from competitors reselling the software as a service, and (3) maintains positive developer community sentiment.

**Recommendation**: The **Functional Source License (FSL-1.1-ALv2)** is the strongest option for Synaptic Assistant. It provides clear non-compete protection for the cloud business, converts to Apache 2.0 after two years (building community trust), and has the best community reception among source-available licenses. It is the license used by Sentry, GitButler, Codecov, and others. An alternative worth considering is the **Fair Core License (FCL)** if you want built-in license-key support for self-hosted enterprise features.

---

## Background: The Problem Being Solved

Synaptic Assistant needs a license that solves the "cloud free-rider" problem: preventing AWS, GCP, or other providers from taking the open-source code and offering it as a competing managed service without contributing back. Traditional permissive licenses (MIT, Apache 2.0) offer no protection. Traditional copyleft (GPL, AGPL) is often insufficient or creates adoption barriers.

---

## License Options Evaluated

### 1. Functional Source License (FSL)

**Created by**: Sentry (2023)
**Category**: Fair Source (source-available with guaranteed open-source conversion)
**Website**: https://fsl.software/

**How it works**:
- Users can read, run, modify, and redistribute the software for any purpose EXCEPT "Competing Use"
- "Competing Use" = offering a commercial product or service that competes with the licensor's products
- After **two years**, each version automatically and irrevocably converts to **Apache 2.0** (or MIT, depending on variant chosen)
- Two variants: `FSL-1.1-ALv2` (converts to Apache 2.0) and `FSL-1.1-MIT` (converts to MIT)

**What it allows**:
- Internal business use (any company can use it internally)
- Modification and redistribution
- Consulting and support services around the software
- Building products that USE the software (not compete with it)
- Academic and personal use

**What it prohibits**:
- Offering a competing commercial product or service (e.g., a hosted Synaptic Assistant clone)

**Adopters**: Sentry, Codecov, GitButler, PowerSync, Convex, Answer Overflow, Sweetr, Liquibase Community

**Community reception**: Mixed but generally the best-received among source-available licenses. Sentry developed it openly over two months with community input. Critics argue it is still proprietary gatekeeping; supporters appreciate the honesty and the guaranteed conversion to true open source. Armin Ronacher (Flask/Jinja creator, Sentry CTO) has written extensively on why FSL is superior to AGPL for single-vendor projects, arguing that FSL's power diminishes over time while AGPL + CLA concentrates power permanently.

**Key advantage**: The two-year conversion is a concrete, irrevocable promise. If the company dies, the community can fork freely within two years. This addresses the biggest concern with source-available licenses.

---

### 2. Fair Core License (FCL)

**Created by**: Keygen (2024)
**Category**: Fair Source (source-available with guaranteed open-source conversion)
**Website**: https://fcl.dev/

**How it works**:
- Nearly identical to FSL in structure
- Non-compete restriction for two years, then converts to Apache 2.0 or MIT
- Key differentiator: **built-in license-key support** for monetizing self-hosted software features

**What it allows/prohibits**: Same as FSL (non-compete restriction only)

**Adopters**: Keygen, and a growing list at fss.cool

**Community reception**: Newer, less battle-tested. Seen as an FSL derivative with added commercialization tooling.

**Key advantage over FSL**: If you want to gate certain self-hosted features behind a license key (open-core model with enterprise features), FCL was designed with this pattern in mind.

---

### 3. Business Source License (BUSL 1.1)

**Created by**: MariaDB Corporation (2013)
**Category**: Fair Source (source-available with guaranteed open-source conversion)
**Website**: https://mariadb.com/bsl11/

**How it works**:
- Source code is available but restricted by an "Additional Use Grant" that varies per project
- Each licensor defines their own restrictions in the Additional Use Grant
- After **four years** (configurable, max 4), converts to a specified open-source license (typically GPL v2+)

**What it allows/prohibits**: Varies per project -- each licensor writes their own Additional Use Grant, which creates ambiguity

**Adopters**: MariaDB (MaxScale), HashiCorp (Terraform, Vault, Nomad), CockroachDB, Couchbase, Confluent

**Community reception**: **Significantly negative**. HashiCorp's 2023 switch from MPL to BUSL triggered immediate backlash:
- The OpenTF Manifesto was signed by hundreds of organizations
- The Linux Foundation accepted OpenTofu as an open-source fork of Terraform
- OpenTofu described BUSL as "ambiguous" and "challenging for companies, vendors, and developers"
- The variable Additional Use Grant means every BUSL project has different rules, creating legal uncertainty

**Key disadvantage**: The Additional Use Grant variability is the fatal flaw. Every BUSL project is effectively a custom license, making it hard for developers to reason about their rights.

---

### 4. Server Side Public License (SSPL)

**Created by**: MongoDB (2018)
**Category**: Source-available (NOT Fair Source -- no DOSP provision)

**How it works**:
- Based on AGPL v3, with Section 13 modified to require that anyone offering the software as a service must release the **entire** service stack as open source (including management tools, monitoring, backup, etc.)
- This requirement is so expansive that it is effectively impossible to comply with, making it a de facto commercial-use prohibition

**What it allows**: Internal use, modification, redistribution (with same SSPL terms)
**What it prohibits**: Effectively prohibits offering as a cloud service (the compliance requirement is unrealistically broad)

**Adopters**: MongoDB (until 2024 switch to SSPL+proprietary), Redis (briefly in 2024, then reverted to AGPL v3), Elastic (briefly)

**Community reception**: **Very negative**.
- **Not recognized** as open source by OSI, Red Hat, Debian, or Fedora
- MongoDB submitted it for OSI approval and withdrew after criticism
- Redis adopted SSPL in early 2024 and reversed course to AGPL v3 within a year due to backlash
- Called "discriminatory" by OSI
- Often dropped from Linux distributions

**Key disadvantage**: Maximum community hostility. No conversion to open source. Practically impossible compliance terms. Multiple high-profile reversals (Redis, Elastic).

---

### 5. n8n Sustainable Use License

**Created by**: n8n GmbH (2022)
**Category**: Fair-code (source-available, custom license, NO open-source conversion)
**Website**: https://docs.n8n.io/sustainable-use-license/

**How it works**:
- Based on Elastic License 2.0 (with permission from Elastic)
- Replaced n8n's previous Apache 2.0 + Commons Clause license
- Allows use for "internal business purposes" only
- Prohibits selling products/services where value "derives entirely or substantially" from n8n functionality

**Dual-license structure**:
- Community code: Sustainable Use License
- Enterprise features: Proprietary n8n Enterprise License (files containing `.ee.` in filename)

**What it allows**: Internal use, modification, self-hosting, personal/non-commercial use
**What it prohibits**: Reselling, offering as a competing service, embedding as a backend for commercial products

**Community reception**: Generally accepted by n8n's community, though some confusion about what "internal business purposes" means exactly. Some users report uncertainty about whether their specific use case is permitted.

**Key disadvantage**: Custom, one-off license (not a standard). No open-source conversion (unlike FSL/BUSL). The "substantially" language creates ambiguity. Only n8n uses it, so there is no ecosystem of shared understanding.

---

### 6. Commons Clause

**Created by**: Heather Meeker (2018)
**Category**: License addendum (not a standalone license)

**How it works**:
- An addendum applied on top of an existing open-source license (e.g., Apache 2.0 + Commons Clause)
- Adds a restriction: you cannot "Sell" the software, where "Sell" means providing a product/service whose value "derives, entirely or substantially, from the functionality of the Software"
- Was n8n's original approach (Apache 2.0 + Commons Clause, before switching to SUL)

**Community reception**: **Negative**.
- The "substantially" language is vague and legally untested
- Applying it to Apache 2.0 created confusion -- people expected Apache 2.0 permissions
- OSI explicitly stated Commons Clause makes a license non-open-source
- Redis used it briefly before switching to SSPL (then to AGPL v3)
- n8n abandoned it for the Sustainable Use License
- RedMonk called it "Tragedy of the Commons Clause"

**Key disadvantage**: Ambiguous, poorly received, and largely abandoned by its major adopters. Should be considered obsolete.

---

### 7. Fair License

**Category**: OSI-approved permissive open-source license
**Full text**: `Usage of the works is permitted provided that this instrument is retained with the works, so that any entity that uses the works is notified of this instrument. DISCLAIMER: THE WORKS ARE WITHOUT WARRANTY.`

This is a two-line ultra-permissive license similar to MIT/ISC. It provides **zero protection** for a cloud business model. The user likely confused this with the "Fair Source" movement. **Not recommended for this use case.**

---

### 8. AGPL v3 (Comparison Point)

**Category**: OSI-approved copyleft open-source license

**How it works**: Requires that anyone who modifies the software AND offers it as a network service must make the complete source code available to users of that service.

**Why some companies use it for open-core**: AGPL's network-use clause discourages (but does not prevent) cloud providers from offering the software as a service without contributing back.

**Key problems for this use case**:
- Many companies have blanket policies against AGPL software (Google, Apple, etc.)
- Does not actually prevent competition -- competitors can comply by publishing their modifications
- With a CLA (Contributor License Agreement), the company retains sole relicensing rights, creating a power asymmetry that FSL handles more honestly
- The copyleft "viral" nature can scare away enterprise adopters

---

## Comparison Matrix

| Criterion | FSL | FCL | BUSL | SSPL | n8n SUL | Commons Clause | AGPL |
|-----------|-----|-----|------|------|---------|----------------|------|
| **Protects cloud business** | Yes (non-compete) | Yes (non-compete) | Yes (custom grant) | Yes (extreme) | Yes (internal-only) | Yes (no-sell) | Weak |
| **Internal use allowed** | Yes | Yes | Varies | Yes | Yes | Yes | Yes |
| **Modification allowed** | Yes | Yes | Yes | Yes (SSPL terms) | Yes | Yes | Yes (AGPL terms) |
| **Converts to OSS** | 2 years (Apache/MIT) | 2 years (Apache/MIT) | 4 years (GPL+) | Never | Never | Never | Already OSS |
| **OSI-approved** | No | No | No | No | No | No | Yes |
| **Standard/reusable** | Yes (used by 9+ cos) | Yes (newer) | Yes (variable grants) | Yes (but toxic) | No (custom, n8n only) | Yes (but abandoned) | Yes |
| **Community reception** | Good (for non-OSS) | Neutral (new) | Negative (forks) | Very negative | Neutral | Negative | Positive (but feared) |
| **Legal clarity** | High (opinionated) | High | Low (variable grants) | Low (extreme terms) | Medium | Low ("substantially") | Medium (copyleft scope) |
| **Contributor friendliness** | Good (future Apache) | Good (future Apache) | OK (future GPL) | Poor | OK | Poor | OK (but CLA needed) |
| **Enterprise adoption** | Good (non-viral) | Good (non-viral) | Varies | Poor | OK | Poor | Poor (many ban AGPL) |

---

## Analysis for Synaptic Assistant

### Use Case Requirements

1. **Desktop app**: Users download and run locally -- must be freely usable
2. **Self-hosting**: Users should be able to self-host for personal/internal use
3. **Cloud tier**: Paid hosted version -- must be protected from competitors
4. **Community contributions**: Want an active contributor community
5. **Enterprise-friendly**: Want enterprises to be able to use the desktop app without legal friction

### Why FSL is the Best Fit

1. **Clear non-compete**: Directly prevents competing cloud offerings without ambiguity
2. **Two-year conversion**: Builds genuine trust -- code becomes Apache 2.0, giving the community a real safety net
3. **Non-viral**: Enterprises can use it without triggering copyleft concerns (unlike AGPL)
4. **Growing adoption**: Sentry, GitButler, Codecov provide precedent and shared understanding
5. **Honest positioning**: Does not pretend to be open source -- "Fair Source" is a distinct, honest category
6. **Contributor-friendly**: Contributors know their code will become Apache 2.0 in two years
7. **Battle-tested**: Sentry has used it since 2023 without major legal issues

### Enterprise Features Strategy

For features exclusive to the paid cloud tier or enterprise self-hosted licenses, consider the n8n pattern:
- Core code: FSL-1.1-ALv2
- Enterprise/cloud-only features: Proprietary license (separate files, clearly marked)
- This dual-license approach is well-understood in the industry

Alternatively, use FCL instead of FSL if you want built-in license-key gating for self-hosted enterprise features.

---

## Recommendation

### Primary: FSL-1.1-ALv2 (Functional Source License, converting to Apache 2.0)

**For the core Synaptic Assistant codebase**:
- Apply FSL-1.1-ALv2 to all community source code
- This allows anyone to use, modify, and self-host for non-competing purposes
- After two years, each version becomes Apache 2.0 -- genuinely open source
- Competing cloud services are prohibited during the two-year window

**For enterprise/cloud-exclusive features**:
- Use a separate proprietary license for cloud-only or enterprise features
- Follow n8n's `.ee.` file naming convention or a similar clear boundary
- This gives you a monetization path beyond just hosting

**For contributor agreements**:
- Consider a lightweight CLA or DCO (Developer Certificate of Origin)
- FSL's Apache 2.0 conversion reduces the power asymmetry concern that CLAs normally create

### Why Not the Others

| License | Why Not |
|---------|---------|
| BUSL | Four-year conversion too long; variable Additional Use Grant creates ambiguity; community backlash (OpenTofu fork) |
| SSPL | Maximum community hostility; not recognized by OSI, Debian, Red Hat; multiple reversals |
| n8n SUL | Custom one-off license; no open-source conversion; no ecosystem |
| Commons Clause | Abandoned by major adopters; ambiguous; considered obsolete |
| AGPL | Does not actually prevent competition; enterprise adoption barriers; power asymmetry with CLA |
| FCL | Viable alternative if license-key gating needed, but less battle-tested than FSL |
| Fair License | Ultra-permissive; zero cloud protection |

---

## Implementation Notes

1. **License file**: Place `LICENSE.md` at repo root with FSL-1.1-ALv2 text
2. **File headers**: Add SPDX identifier to source files: `// SPDX-License-Identifier: FSL-1.1-ALv2`
3. **Enterprise boundary**: Clearly separate enterprise features in a dedicated directory or with naming convention
4. **NOTICE file**: Maintain attribution for dependencies
5. **README**: State the license clearly, link to FSL website, explain what users can and cannot do in plain language
6. **Change Date**: Each release has its own two-year conversion date; this is automatic per the FSL terms

---

## References

- [FSL Website](https://fsl.software/)
- [FSL GitHub](https://github.com/getsentry/fsl.software)
- [Sentry FSL Announcement](https://blog.sentry.io/introducing-the-functional-source-license-freedom-without-free-riding/)
- [FSL vs AGPL (Armin Ronacher)](https://lucumr.pocoo.org/2024/9/23/fsl-agpl-open-source-businesses/)
- [Fair Source Movement](https://fair.io/)
- [Fair Core License](https://fcl.dev/)
- [n8n Sustainable Use License](https://docs.n8n.io/sustainable-use-license/)
- [n8n License Announcement](https://blog.n8n.io/announcing-new-sustainable-use-license/)
- [HashiCorp BSL Adoption](https://www.hashicorp.com/en/blog/hashicorp-adopts-business-source-license)
- [SSPL Wikipedia](https://en.wikipedia.org/wiki/Server_Side_Public_License)
- [Commons Clause](https://commonsclause.com/)
- [TechCrunch: Fair Source Startups](https://techcrunch.com/2024/09/22/some-startups-are-going-fair-source-to-avoid-the-pitfalls-of-open-source-licensing/)
- [Redis SSPL Reversal](https://www.infoq.com/news/2024/03/redis-license-open-source/)
- [FOSSA: Fall 2024 Licensing Roundup](https://fossa.com/blog/fall-2024-software-licensing-roundup/)
