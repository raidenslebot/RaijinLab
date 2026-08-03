import re, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

c = open(r'C:\Ascension\Launcher\resources\ascension-live\Logs\raijinlab_config_2.lua',
         encoding='utf-8', errors='replace').read()

# Every top-level "slots" dict: [N] = { slot }
for m in re.finditer(r'\["slots"\]=\{(.*?)\},\},?\s*\}\},?', c, re.S):
    block = m.group(1)
    if '45477' not in block:
        continue
    pre = c[:m.start()]
    names = re.findall(r'\["name"\]="([^"]+)"', pre)
    rot = names[-1] if names else '?'
    slots = re.findall(
        r'\[(\d+)\]=\{\["enabled"\]=true,\["while_casting"\]=false,'
        r'\["id"\]="([0-9-]+)",\["off_gcd"\]=false,\["name"\]="([^"]+)",'
        r'\["spell_id"\]=(\d+),\["conditions"\]=\{(.*?)\},\["action_type"\]="spell"',
        block, re.S)
    print('ROTATION:', rot)
    for idx, sid, name, spell, conds in sorted(slots, key=lambda x: int(x[0])):
        states = re.findall(r'state"\]="([a-z]+)"', conds)
        aura_names = re.findall(r'name"\]="([^"]*)"', conds)
        cond_ids = re.findall(r'\["id"\]="([a-z_]+)"', conds)
        print('  [%s] %s sid=%s id=%s conds=%s aura=%s'
              % (idx, name, spell, sid, cond_ids, list(zip(states, aura_names))))
    print()
