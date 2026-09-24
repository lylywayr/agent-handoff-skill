#!/usr/bin/env python3
"""Local-only acceptance probes for the unified agent-handoff contract.
No network access, user repository changes, or remote writes.
"""
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
S = (ROOT / 'SKILL.md').read_text()
W = (ROOT / 'references/workflow-contract.md').read_text()
M = (ROOT / 'references/project-memory-schema.md').read_text()
for needle in ['§0–§14', '### 15.0', '### 15.1', '### 15.2', 'CONFLICT/未同步', '不默认创建 `dev`', '§8 检查凭据']:
    assert needle in S, needle
for needle in ['权限门槛', '状态机', 'If-Match', '不重复', '非 Git 知识库最低契约']:
    assert needle in W, needle
assert 'PC-20260924-001' not in M

def git(*args, cwd=None, ok=True):
    p = subprocess.run(['git', *args], cwd=cwd, text=True, capture_output=True)
    if ok and p.returncode:
        raise AssertionError(f'git {args}: {p.stderr}')
    return p

with TemporaryDirectory(prefix='agent-continuity-') as t:
    d = Path(t); bare = d/'remote.git'; a = d/'a'; b = d/'b'
    git('init', '--bare', str(bare))
    a.mkdir(); git('init', '-b', 'trunk', cwd=a)
    git('config','user.name','Acceptance',cwd=a); git('config','user.email','acceptance@example.invalid',cwd=a)
    (a/'docs/project-memory/logs').mkdir(parents=True)
    (a/'README.md').write_text('# Example\n')
    (a/'docs/project-memory/INDEX.md').write_text('# Project index\n')
    (a/'docs/project-memory/STATUS.md').write_text('# Current status\n')
    rid = 'PC-20260924T063000Z-' + uuid.uuid4().hex[:6]
    (a/'docs/project-memory/logs/2026.md').write_text('## ' + rid + ' initial state\n')
    git('add', 'README.md', 'docs', cwd=a); git('commit','-m','initialize',cwd=a)
    git('remote','add','origin',str(bare),cwd=a)
    git('push','-u','origin','trunk',cwd=a)
    assert git('--git-dir='+str(bare),'show-ref','--verify','refs/heads/trunk').returncode == 0
    assert git('branch','--list','dev',cwd=a).stdout.strip() == ''
    git('clone','-b','trunk',str(bare),str(b))
    git('config','user.name','Acceptance',cwd=b); git('config','user.email','acceptance@example.invalid',cwd=b)
    (a/'README.md').write_text('# Example\nA update\n'); git('add','README.md',cwd=a)
    git('commit','-m','A change',cwd=a); git('push','origin','trunk',cwd=a)
    (b/'README.md').write_text('# Example\nB update\n'); git('add','README.md',cwd=b)
    git('commit','-m','B change',cwd=b)
    old = git('rev-parse','HEAD',cwd=b).stdout.strip()
    rejected = git('push','origin','trunk',cwd=b,ok=False)
    assert rejected.returncode != 0 and git('rev-parse','HEAD',cwd=b).stdout.strip() == old
    git('fetch','origin','trunk',cwd=b)
    assert git('merge-base','--is-ancestor','origin/trunk','HEAD',cwd=b,ok=False).returncode != 0
    assert git('branch','--list','dev',cwd=b).stdout.strip() == ''
    assert git('--git-dir='+str(bare),'show','refs/heads/trunk:README.md').stdout == '# Example\nA update\n'
    assert git('--git-dir='+str(bare),'show','refs/heads/trunk:docs/project-memory/logs/2026.md').stdout.count(rid) == 1
print('PASS: contract markers, trunk initialization, remote verification, rejected concurrent push preserves both states')
