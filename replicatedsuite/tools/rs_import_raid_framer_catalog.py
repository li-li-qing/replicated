"""中文维护：固定版本参考数据转换器；仅解析字面量，不执行外部源码。

开发期运行，不进入 TOC。输入为 RF246 的平铺源码缓存；输出可审计的 Lua
静态表及 JSON 覆盖清单。Skill 树的 id 是槽位，possibleCastIDs 才是游戏 ID。
未知表达式立即失败，禁止静默漏项或把 cooldown/序号解析成游戏 ID。
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

COMMIT = 'fd006560ce2ac968709b263a1a6a8eb6289ec712'
DEFINITIONS = 'composeApp/src/desktopMain/kotlin/com/reoky/raidframer/core/definitions/'
LUA_SOURCE = 'composeApp/src/desktopMain/composeResources/files/RaidFramer/'
TREE_NAMES = ['Archery', 'Auramancy', 'Battlerage', 'Defense', 'Gunslinger', 'Malediction',
              'Occultism', 'Shadowplay', 'Songcraft', 'Sorcery', 'Spelldance', 'Swiftblade',
              'Vitalism', 'Witchcraft']
FILES = [n + 'Definition.kt' for n in TREE_NAMES] + [
    'BlacklistDefinition.kt', 'DebuffsDefinition.kt', 'GliderDefinition.kt',
    'ItemSpellsDefinition.kt', 'LootBuffDefinition.kt', 'MetaSpecsDefinition.kt',
    'OdeDefinition.kt', 'PetSkillDefinition.kt', 'PlayerBehaviorSpellsDefinition.kt',
    'PotionDefinition.kt', 'RaidBuffDefinitions.kt', 'SkillTreeDefinition.kt',
    'SummonDefinition.kt', 'UtilityDefinition.kt', 'combat.lua', 'raid.lua', 'parsers.lua']
CORE = 'composeApp/src/desktopMain/kotlin/com/reoky/raidframer/core/'
INLINE_FILES = {'PetAccumulationInteractor.kt':CORE+'interactor/PetAccumulationInteractor.kt',
                'PlayerCacheInteractor.kt':CORE+'interactor/PlayerCacheInteractor.kt',
                'ProtectiveWingsAttributorInteractor.kt':CORE+'interactor/ProtectiveWingsAttributorInteractor.kt',
                'PlayerCardExtensions.kt':CORE+'model/PlayerCardExtensions.kt'}
FILES += list(INLINE_FILES)


def clean(text, lua=False):
    # 保留字符串与换行位置，移除注释；不会把注释中旧的无效 ID 当有效数据。
    pattern = r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|--\[\[[\s\S]*?\]\]|--[^\n]*' if lua else r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\n]*'
    return re.sub(pattern, lambda m: m[0] if m[0].startswith(('"', "'")) else re.sub(r'[^\n]', ' ', m[0]), text)


def closing(text, start):
    stack, quoted, escape = [], False, False
    for i in range(start, len(text)):
        c = text[i]
        if quoted:
            if escape: escape = False
            elif c == '\\': escape = True
            elif c == '"': quoted = False
            continue
        if c == '"': quoted = True
        elif c in '({[': stack.append(c)
        elif c in ')}]':
            if not stack or stack.pop() != {')': '(', '}': '{', ']': '['}[c]:
                raise ValueError('unbalanced literal')
            if not stack: return i
    raise ValueError('unterminated literal')


def split(text):
    out, start, i = [], 0, 0
    while i < len(text):
        c = text[i]
        if c == '"':
            m = re.match(r'"(?:\\.|[^"\\])*"', text[i:])
            if not m: raise ValueError('unterminated string')
            i += len(m[0]); continue
        if c in '({[': i = closing(text, i) + 1; continue
        if c == ',':
            if text[start:i].strip(): out.append(text[start:i].strip())
            start = i + 1
        i += 1
    if text[start:].strip(): out.append(text[start:].strip())
    return out


def literal(value):
    value = value.strip()
    if value.startswith('"'): return json.loads(value)
    if re.fullmatch(r'-?\d+(?:\.\d+)?[Lf]?', value):
        n = value.rstrip('Lf'); return float(n) if '.' in n else int(n)
    if value in ('true', 'false', 'null'): return {'true': True, 'false': False, 'null': None}[value]
    m = re.fullmatch(r'(?:listOf|setOf|emptyList|emptySet)(?:<[^>]+>)?\(([\s\S]*)\)', value)
    if m: return [literal(x) for x in split(m[1])]
    if re.fullmatch(r'(?:Res\.(?:string|drawable)|SkillTreeType|RaidBuffKey|RaidBuffSection|SpecType)\.[A-Za-z_0-9]+', value):
        return value.split('.')[-1]
    raise ValueError('unsupported data literal: ' + value[:120])


def arguments(text, positional):
    result = {}
    for i, part in enumerate(split(text)):
        m = re.match(r'^([A-Za-z_]\w*)\s*=\s*([\s\S]*)$', part)
        key, value = (m[1], m[2]) if m else (positional[i], part)
        # 只提取定义中的数据字段，不搬运 updateCard 等工程表达式。
        if key in ('updateCard', 'packedUsageField'): continue
        result[key] = literal(value)
    return result


def calls(text, name):
    for m in re.finditer(r'\b' + re.escape(name) + r'\s*\(', text):
        if re.search(r'(?:class|fun)\s*$', text[max(0, m.start()-20):m.start()]): continue
        start = text.index('(', m.start())
        yield m.start(), text[start+1:closing(text, start)]


def lua(value):
    if value is None: return 'nil'
    if value is True: return 'true'
    if value is False: return 'false'
    if isinstance(value, str):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'
    if isinstance(value, (int, float)): return str(value)
    if isinstance(value, list): return '{' + ', '.join(lua(x) for x in value) + '}'
    if isinstance(value, dict): return '{' + ', '.join('['+lua(k)+']='+lua(v) for k,v in value.items() if v is not None) + '}'
    raise TypeError(type(value))


def inline_ids(text):
    """补充定义目录外的明确 ID 字段，不抽取伤害数值、时间、CID 或 UI 序号。"""
    for m in re.finditer(r'\bval\s+(\w+(?:Id|Ids|ID|IDS))\s*(?::[^=\n]+)?=\s*((?:setOf|listOf)\([^)]*\)|\d+)',text):
        name=m[1];upper=name.upper();values=literal(m[2]);ids=values if isinstance(values,list) else [values]
        if 'BUFF' in upper:namespace='buff'
        elif any(token in upper for token in ('SPELL','SKILL','CAST','DAMAGE','RIDER')):namespace='skill'
        else:raise ValueError('unclassified inline ID field: '+name)
        yield m.start(),name,namespace,[x for x in ids if x>0]
    for m in re.finditer(r'\b(\w*(?:buffId|debuffId|spellId|skillId|SpellId))\s*(?:==|!=)\s*(\d+)',text):
        value=int(m[2])
        if value>0:yield m.start(),m[1]+'@'+str(m.start()),'buff' if 'buff' in m[1].lower() else 'skill',[value]
    for m in re.finditer(r'\b(\w*(?:buffId|debuffId|spellId|skillId|SpellId))\s+in\s+setOf\(([^)]*)\)',text):
        yield m.start(),m[1]+'@'+str(m.start()),'buff' if 'buff' in m[1].lower() else 'skill',literal('setOf('+m[2]+')')


def convert(cache):
    records, trees, specs, roles, sources, anomalies = [], {}, [], {}, [], []
    binding_text=clean((cache/'SkillTreeDefinition.kt').read_text(encoding='utf-8-sig'))
    tree_bindings={definition+'.kt':tree for tree,definition in re.findall(r'^  (\w+)\((\w+Definition)\)[,;]?\s*$',binding_text,re.M)}
    if len(tree_bindings)!=14:raise ValueError('incomplete canonical tree bindings')
    def add(file, line, symbol, family, skill_ids=(), buff_ids=(), names=(), **extra):
        for ids in (skill_ids, buff_ids):
            if any(type(x) is not int or x <= 0 for x in ids): raise ValueError('invalid game id: ' + symbol)
        row = dict(key=file + ':' + symbol, family=family, skillIds=list(dict.fromkeys(skill_ids)),
                   buffIds=list(dict.fromkeys(buff_ids)), names=list(dict.fromkeys(names)),
                   sourceFile=file, sourceLine=line, verification='reference_unverified_ru')
        if any(existing['key']==row['key'] for existing in records):
            anomalies.append(dict(sourceFile=file,kind='duplicate_definition',key=row['key'],sourceLine=line,
                                  resolution='retain both records; no last-write-wins'))
            row['key']+='@'+str(line)
        row.update(extra); records.append(row)
    for file in FILES:
        path = cache / file
        raw = path.read_bytes(); original = raw.decode('utf-8-sig')
        text = clean(original, file.endswith('.lua'))
        before = len(records)
        line = lambda pos: text[:pos].count('\n') + 1
        if file[:-13] in TREE_NAMES:  # FooDefinition.kt
            declared_tree = re.search(r'override val tree = SkillTreeType\.(\w+)', text)[1]
            tree = tree_bindings[file]
            game_id = int(re.search(r'override val gameId = (\d+)', text)[1])
            trees[tree] = dict(gameId=game_id, sourceFile=file,declaredTree=declared_tree)
            if declared_tree!=tree:
                anomalies.append(dict(sourceFile=file,kind='tree_declaration_conflict',declared=declared_tree,
                                      canonical=tree,resolution='SkillTreeType enum binding; retain original declaration'))
            for pos, body in calls(text, 'Skill'):
                r = arguments(body, ['id','name','castTime','cooldown','possibleNames'])
                add(file, line(pos), tree+':'+str(r['id']), 'skill_tree', r.get('possibleCastIDs', []),
                    names=[r['name']]+r.get('possibleNames', []), tree=tree, slotIndex=r['id'],
                    castTime=r['castTime'], cooldown=r['cooldown'])
        elif file == 'PetSkillDefinition.kt':
            for pos, body in calls(text, 'Skill'):
                r = arguments(body, ['id','name','castTime','cooldown','possibleNames'])
                add(file, line(pos), str(r['id']), 'pet', [r['id']]+r.get('relatedDamageIds', []),
                    names=[r['name']]+r.get('possibleNames', []), canonicalSkillId=r['id'],
                    relatedDamageIds=r.get('relatedDamageIds', []), allowedPetTypes=r.get('allowedPetTypes', []),
                    isPetInitiator=r.get('isPetInitiator', False), castTime=r['castTime'], cooldown=r['cooldown'])
        elif file == 'PlayerBehaviorSpellsDefinition.kt':
            for pos, body in calls(text, 'PlayerBehaviorSpell'):
                r = arguments(body, ['spellId','spellName','description'])
                add(file, line(pos), str(r['spellId']), 'player_behavior', [r['spellId']],
                    names=[r['spellName']], description=r['description'])
        elif file == 'DebuffsDefinition.kt':
            for m in re.finditer(r'^val (\w+(?:Ids|Id))\s*(?:[^=\n]+)?=\s*', text, re.M):
                start = m.end(); end = text.find('\n', start)
                if m[1]=='areaEffectBuffIds':
                    if text[start:end].strip()!='areaEffectSpellConfigs.flatMap { it.auraBuffIds }.toSet()':
                        raise ValueError('area-effect derived expression changed')
                    continue  # 派生集合已由下方每个 AreaEffectSpellConfig 完整保留。
                if re.match(r'(?:listOf|setOf)\(', text[start:]):
                    op = text.index('(', start); end = closing(text, op)+1
                values = literal(text[start:end]); ids = values if isinstance(values,list) else [values]
                is_skill = 'Cast' in m[1] or 'Spell' in m[1]
                add(file, line(m.start()), m[1], 'effect_group', ids if is_skill else [], [] if is_skill else ids,
                    group=m[1], declaredKind='unknown' if is_skill else ('debuff' if 'Debuff' in m[1] else 'buff'))
            for i,(pos,body) in enumerate(calls(text, 'Debuff')):
                r = arguments(body, ['ids','name','consideredCC'])
                add(file, line(pos), 'debuff:'+str(i), 'control', buff_ids=r['ids'], names=[r['name']],
                    consideredCC=r['consideredCC'], declaredKind='debuff')
            for i,(pos,body) in enumerate(calls(text, 'AreaEffectSpellConfig')):
                r = arguments(body, [])
                add(file, line(pos), 'area:'+str(i), 'area_effect', buff_ids=r['auraBuffIds'], names=r['damageSpellNames'],
                    displayName=r['name'], appliesToAllies=r['appliesToAllies'],
                    correlationWindowMs=r.get('correlationWindowMs',2000), areaLifetimeMs=r.get('areaLifetimeMs',7000))
        elif file in ('ItemSpellsDefinition.kt', 'GliderDefinition.kt', 'PotionDefinition.kt'):
            family = {'ItemSpellsDefinition.kt':'item','GliderDefinition.kt':'glider','PotionDefinition.kt':'potion'}[file]
            # 枚举项必须是行首声明，避免把方法调用及资源 import 当条目。
            for m in re.finditer(r'^  ([A-Z][A-Za-z_0-9]*)\(', text, re.M):
                op = text.index('(',m.start()); body = text[op+1:closing(text,op)]
                r = arguments(body, ['skillId','cooldown','friendlyNameRes','possibleSpellNames'])
                skills = r.get('itemSpecificSkillIds', [r['skillId']] if 'skillId' in r else [])
                buffs = r.get('itemSpecificBuffIds', r.get('buffIds', []))
                add(file, line(m.start()), m[1], family, skills, buffs, r.get('possibleSpellNames', []),
                    displayName=m[1], labelKey=r['friendlyNameRes'], iconResource=r.get('iconRes'),
                    castTime=r.get('castTime'), cooldown=r['cooldown'], nameMatchEnabled=family!='potion')
        elif file == 'LootBuffDefinition.kt':
            for pos,body in calls(text,'LootBuffDefinition'):
                r=arguments(body,['buffId','name','lootPercent','durationSeconds'])
                add(file,line(pos),str(r['buffId']),'loot',buff_ids=[r['buffId']],names=[r['name']],
                    lootPercent=r['lootPercent'],durationSeconds=r.get('durationSeconds'),declaredKind='buff')
        elif file == 'RaidBuffDefinitions.kt':
            for pos,body in calls(text,'RaidBuffDefinition'):
                r=arguments(body,['key','ids','labelKey','section'])
                add(file,line(pos),r['key'],'raid_buff',buff_ids=r['ids'],displayName=r['key'],labelKey=r['labelKey'],
                    section=r.get('section','MAIN'),enhancedIds=r.get('enhancedIds',[]),
                    orangeIds=r.get('orangeIds',[]),meatballIds=r.get('meatballIds',[]),declaredKind='buff')
        elif file == 'BlacklistDefinition.kt':
            for m in re.finditer(r'val (blacklisted\w+)\s*:[^=]+?=\s*setOf\(',text):
                op=text.index('(',m.start()); vals=literal(text[op-5:closing(text,op)+1])
                is_id=m[1].endswith('Ids')
                add(file,line(m.start()),m[1],'graph_exclusion',buff_ids=vals if is_id else [],names=[] if is_id else vals,
                    group=m[1],declaredKind='debuff' if 'Debuff' in m[1] else 'buff',exclusionScope='reference_battle_graph_only')
        elif file == 'OdeDefinition.kt':
            m=re.search(r'val odeSpellNamesI18N = listOf\(',text);op=text.index('(',m.start())
            add(file,line(m.start()),'odeSpellNamesI18N','song',names=literal(text[op-6:closing(text,op)+1]),nameMatchMode='contains')
        elif file == 'SkillTreeDefinition.kt':
            for m in re.finditer(r'^  ([A-Z_]+)\(setOf\(([^\n]*)\)\)',text,re.M):
                vals=literal('setOf('+m[2]+')')
                if vals: specs.append(dict(key=m[1],trees=vals,sourceFile=file,sourceLine=line(m.start())))
            for m in re.finditer(r'val (META_\w+) = setOf<SpecType>\(',text):
                op=text.index('(',m.start());roles[m[1]]=literal('setOf('+text[op+1:closing(text,op)]+')')
            m=re.search(r'val initiatingSpells = listOf\(',text);op=text.index('(',m.start())
            add(file,line(m.start()),'initiatingSpells','initiating_spell',names=literal(text[op-6:closing(text,op)+1]))
        elif file == 'raid.lua':
            for m in re.finditer(r'RF\.Raid\.(\w+BUFF_IDS)\s*=\s*\{',text):
                op=text.index('{',m.start());body=text[op+1:closing(text,op)]
                ids=[int(x) for x in re.findall(r'\[(\d+)\]\s*=\s*true',body)]
                add(file,line(m.start()),m[1],'collector_hint',buff_ids=ids,group=m[1])
            # tooltip 专项涉及的状态全部保留，但不启用扫描或 tooltip 读取。
            ids=sorted({int(x) for x in re.findall(r'\b(?:buffId|buff_id)\s*==\s*(\d+)',text)})
            if ids:add(file,1,'tooltip_effect_ids','collector_hint',buff_ids=ids)
        elif file == 'combat.lua':
            # 名称仅表达参考服的阵营识别规则，不据此写入 UnitIdentity。
            for label,start,end in [('HARANYA',30767,30766),('NUIA',30766,30768),('PIRATE',30768,None)]:
                startpos=text.index('(buffId == '+str(start)+')');endpos=text.index('(buffId == '+str(end)+')',startpos) if end else text.index('end',startpos)
                ids=[int(x) for x in re.findall(r'buffId == (\d+)',text[startpos:endpos])]
                add(file,line(startpos),'statue:'+label,'faction_hint',buff_ids=ids,displayName=label)
        elif file in INLINE_FILES:
            for pos,symbol,namespace,ids in inline_ids(text):
                add(file,line(pos),symbol,'inline_reference',skill_ids=ids if namespace=='skill' else [],
                    buff_ids=ids if namespace=='buff' else [],group=file+':'+symbol)
        elif file not in ('parsers.lua','MetaSpecsDefinition.kt','SummonDefinition.kt','UtilityDefinition.kt'):
            raise ValueError('unhandled source: '+file)
        sources.append(dict(path=INLINE_FILES.get(file,(LUA_SOURCE if file.endswith('.lua') else DEFINITIONS)+file),
                            sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw),records=len(records)-before))
    if len(trees)!=14 or len(specs)!=364: raise ValueError('incomplete tree/spec definitions: '+str((len(trees),len(specs))))
    if len({r['key'] for r in records})!=len(records):raise ValueError('duplicate record key')
    for spec in specs:
        if len(set(spec['trees']))!=3 or any(x not in trees for x in spec['trees']):raise ValueError('invalid spec: '+spec['key'])
    counts={family:sum(r['family']==family for r in records) for family in sorted({r['family'] for r in records})}
    skills=sorted({i for r in records for i in r['skillIds']});buffs=sorted({i for r in records for i in r['buffIds']})
    return dict(version=1,provenance=dict(project='Raid Framer',release='RF246',commit=COMMIT,
                repository='https://github.com/barcodeguild/raid-framer-desktop',verification='reference_unverified_ru'),
                records=records,trees=trees,specs=specs,metaRoles=roles,sourceFiles=sources,anomalies=anomalies,
                counts=dict(records=len(records),skills=len(skills),buffs=len(buffs),trees=len(trees),specs=len(specs),families=counts))


def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True)
    args=p.parse_args();data=convert(args.source)
    header='-- 中文维护（2026-10-05）：固定 RF246 的识别数据字面量；由 tools/rs_import_raid_framer_catalog.py 转换。\n-- 保留参考语义与来源；全部 reference_unverified_ru，不能冒充 RU 实测或直接改变状态极性。\nif ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end\nReplicatedSuite.Data = ReplicatedSuite.Data or {}\n'
    fields=[]
    for k,v in data.items():
        if k in ('records','specs','sourceFiles'):
            fields.append('    '+k+' = {\n'+''.join('        '+lua(row)+',\n' for row in v)+'    },\n')
        else:fields.append('    '+k+' = '+lua(v)+',\n')
    args.output.write_text(header+'ReplicatedSuite.Data.CombatRecognitionSource = {\n'+''.join(fields)+'}\n',encoding='utf-8')
    args.manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(data['counts'],ensure_ascii=False));print('sources='+str(len(data['sourceFiles'])))


if __name__=='__main__':main()
