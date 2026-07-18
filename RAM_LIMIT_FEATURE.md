# RAM Limit Feature - Ninja

## Overview (Hindi/English)
Ye feature ninja build me RAM limit lagane ke liye hai. Aap environment variable export karke bol sakte ho ki total kitni RAM use ho.

Example:
```bash
export NINJA_RAM_LIMIT=2g   # 2GB max
# ya
export NINJA_RAM_LIMIT=2048m
# ya
export NINJA_MAX_RAM=2g
# ya
export NINJA_RAM=2g
```

Jitni limit set karoge, utni hi RAM (total running jobs ka sum) lega.

## Kaise kaam karta hai?
- Har edge/job ka RAM requirement `ram` / `memory` binding se aata hai build.ninja se.
  - Example: `ram = 500m` ya `ram = 1g`
  - Agar rule/edge pe `ram` nahi likha, to default `NINJA_RAM_PER_JOB` use hota hai (default 1GB)
- Scheduler check karta hai: `current_ram_usage + next_job_ram <= limit` ?
  - Agar haan, to job start karo.
  - Agar nahi, to job ko wapas queue me daal do aur wait karo jab tak RAM free na ho.
- Isse parallelism automatically throttle hota hai RAM ke hisaab se.

## Linking wala case: 4GB chahiye par limit 2GB
**Sawal:** Agar `NINJA_RAM_LIMIT=2g` set hai aur linking task ko 4GB chahiye, to kya hoga?

**Jawab:** 
- Naive hard limit (setrlimit) se linking OOM kill ho jayega aur fail hoga.
- Is implementation me **exclusive mode** hai:
  - Agar kisi job ka requirement limit se zyada hai (e.g. 4GB > 2GB), to scheduler pehle saare chote jobs khatam hone deta hai.
  - Jab `current_ram_usage == 0` ho jata hai (koi job nahi chal raha), tab bade job ko akela chalata hai.
  - Warning print hota hai: `RAM limit 2048 MB: edge requiring 4096 MB exceeds limit, running exclusively`
  - Is tarah linking succeed hota hai, peak thoda zyada jata hai (4GB) par average controlled rehta hai aur build fail nahi hota.

Alternative options:
- Aap linking rule ko alag pool me bhi daal sakte ho (`pool = console`) jo limit bypass kare.
- Ya `ram` binding hata do to default pe chalega (par phir bhi exclusive logic lagega).

## Usage Examples

### Env var se
```bash
# Total 2GB limit
export NINJA_RAM_LIMIT=2g
ninja -j8

# Per job default change
export NINJA_RAM_PER_JOB=500m
export NINJA_RAM_LIMIT=2g
ninja -j8  # ab max 4 jobs parallel (4*500m=2g)
```

### build.ninja me per rule
```ninja
rule compile
  command = g++ -c $in -o $out
  ram = 1g

rule link
  command = g++ $in -o $out
  ram = 4g   # linking needs more

build foo.o: compile foo.cc
build bar.o: compile bar.cc
  ram = 2g   # override for this file

build myapp: link foo.o bar.o
```

## Implementation Details
Files changed:
- `src/util.h/.cc`: `ParseRamLimit()` function jo "2g", "512m", "1024", etc parse karta hai -> bytes. No suffix = MB assumed.
- `src/build.h`: `BuildConfig` me `max_ram`, `default_ram_per_job`, `ram_limit_from_env` add kiya. Builder me `current_ram_usage_` aur `running_edge_ram_` tracking.
- `src/build.cc`: `Plan::RequeueEdge()`, `PeekWork()`, `GetEdgeRamRequirement()`, aur main Build loop me RAM check logic. Heavy job > limit -> exclusive mode.
- `src/eval_env.cc`: Rule me `ram`, `memory` variables allow kiye (IsReservedBinding)
- `src/ninja.cc`: Env vars `NINJA_RAM_LIMIT`, `NINJA_MAX_RAM`, `NINJA_RAM`, `NINJA_RAM_PER_JOB` se config fill karta hai. Usage me env var help add kiya.

## Testing
/tmp/ramtest me test kiya:
- No limit: 4 jobs parallel ~3 sec
- 1g limit (500m per job): 2 parallel max ~4 sec
- 500m limit: 1 at a time ~6 sec
- Linking 4g with 2g limit: warning + exclusive run, success.

## Sync strategy (Latest ninja se sync kaise kare aur apna change disable/enable)
Is feature ka default behaviour disabled hai (max_ram=0 -> no limit). Matlab agar env var set nahi hai, to original ninja jaisa hi behave karta hai. Isliye upstream merge me conflict kam hoga.

Phir bhi agar aapko full clean sync chahiye bina apne changes ke, to ye workflow use karo:

### Method 1: Revert - Sync - Re-apply (Requested workflow)
Aapka RAM limit feature ek hi commit me hai. Isko temporarily revert karke upstream sync kar sakte ho.

```bash
# 1. Current branch pe apne changes ka patch backup lo
git format-patch -1 HEAD --stdout > /tmp/ram-limit.patch
# ya
git log --oneline -1

# 2. Apna feature commit revert karo (disable)
git revert HEAD --no-edit   # isse feature disabled ho jayega

# 3. Upstream remote add karo (original ninja-build/ninja)
git remote add upstream https://github.com/ninja-build/ninja.git
git fetch upstream

# 4. Upstream master se sync karo
git merge upstream/master --no-edit
# ya rebase
# git rebase upstream/master

# 5. Ab apna feature wapis lao
git cherry-pick --no-commit HEAD~1  # ya patch apply
# agar revert commit tha to:
git revert HEAD --no-edit   # revert ka revert = feature wapis

# Ya patch se:
git apply /tmp/ram-limit.patch
# ya
git cherry-pick <original-commit-hash>
```

Hamne iske liye ek helper script banaya hai: `scripts/sync_upstream.sh`

```bash
./scripts/sync_upstream.sh
```

### Method 2: Separate feature branch (Recommended for long term)
- `master` branch hamesha upstream ke saath sync rakho (bina feature ke)
- `ram-limit-feature` branch me feature rakho
- Sync karne ke liye:
  ```bash
  git checkout master
  git pull upstream master
  git checkout ram-limit-feature
  git rebase master  # ya merge master
  ```
  Isse conflicts sirf rebase me dikhenge, aap resolve kar sakte ho.

### Method 3: Feature flag via env (Current implementation)
Kyuki feature env var se enable hota hai, agar env var set nahi hai to code path original jaisa hai (sirf ek if check). Isliye aap bina disable kiye bhi sync kar sakte ho, koi break nahi hoga. Sirf merge conflicts resolve karne padenge agar upstream ne `build.cc`/`build.h` me same jagah change kiya ho to.

## Future improvements
- cgroup based hard limit for child processes (optional)
- `pool = ram` named pool support
- `--ram-limit` command line flag (currently only env var)
- Per-pool RAM tracking
