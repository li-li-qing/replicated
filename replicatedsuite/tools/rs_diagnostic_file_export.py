"""中文维护：只读客户端 UDF 的活动 LevelDB 文件，验证导出专用 key 后生成 UTF-8 txt。

不打开数据库写锁、不写原数据库、不执行存档内容、不从废弃 SST 或旧账号兜底取报告。
支持已观察的 LevelDB legacy SST、无压缩/Snappy、WriteBatch WAL；未知格式明确失败。
"""
from __future__ import annotations
import argparse
from datetime import datetime
from pathlib import Path
import re
import struct
import sys
import zlib
import json
import time
import hashlib
import tempfile


def addon_root():
    """中文维护：发行 exe 使用自身位置，不能使用 one-file 解包临时目录或开发者路径。"""
    entry = Path(sys.executable if getattr(sys, 'frozen', False) else __file__).resolve()
    return entry.parents[2]


def report_folder():
    return addon_root() / '诊断报告'

MAX_BLOCK = 16 * 1024 * 1024
MAILBOX = b'addon_replicatedsuite_replicated_suite_v1_diagnostic_export'
POLY = 0x82F63B78
CRC_TABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (POLY if _c & 1 else 0)
    CRC_TABLE.append(_c)

def crc32c(data):
    value = 0xFFFFFFFF
    for byte in data:
        value = CRC_TABLE[(value ^ byte) & 255] ^ (value >> 8)
    return value ^ 0xFFFFFFFF

def masked_crc(data):
    value = crc32c(data)
    return (((value >> 15) | (value << 17)) + 0xA282EAD8) & 0xFFFFFFFF

def varint(data, pos=0):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError('truncated varint')
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
    raise ValueError('invalid varint')

def field(data, pos):
    size, pos = varint(data, pos)
    if size > MAX_BLOCK or pos + size > len(data):
        raise ValueError('truncated or oversized field')
    return data[pos:pos + size], pos + size

def snappy(data):
    """中文维护：有界原始 Snappy 解码，允许合法重叠拷贝，拒绝越界/超大声明。"""
    expected, pos = varint(data)
    if expected > MAX_BLOCK:
        raise ValueError('Snappy block too large')
    out = bytearray()
    while pos < len(data):
        tag = data[pos]
        pos += 1
        kind = tag & 3
        if kind == 0:
            length = tag >> 2
            if length >= 60:
                width = length - 59
                if pos + width > len(data):
                    raise ValueError('truncated Snappy literal')
                length = int.from_bytes(data[pos:pos + width], 'little')
                pos += width
            length += 1
            if pos + length > len(data) or len(out) + length > expected:
                raise ValueError('Snappy literal out of bounds')
            out.extend(data[pos:pos + length])
            pos += length
        else:
            width = 1 if kind == 1 else (2 if kind == 2 else 4)
            if pos + width > len(data):
                raise ValueError('truncated Snappy copy')
            distance = int.from_bytes(data[pos:pos + width], 'little')
            pos += width
            length = ((tag >> 2) & 7) + 4 if kind == 1 else (tag >> 2) + 1
            if kind == 1:
                distance |= (tag & 224) << 3
            if distance == 0 or distance > len(out) or len(out) + length > expected:
                raise ValueError('Snappy copy out of bounds')
            for _ in range(length):
                out.append(out[-distance])
    if len(out) != expected:
        raise ValueError('Snappy size mismatch')
    return bytes(out)

def log_records(data, allow_tail=False):
    """中文维护：验证物理 log 的 CRC/分片次序；活动 WAL 的未写完尾部不视为已提交记录。"""
    pos, pending = 0, None
    while pos < len(data):
        remain = 32768 - pos % 32768
        if remain < 7:
            pos += remain
            continue
        if pos + 7 > len(data):
            if allow_tail:
                return
            raise ValueError('incomplete log header')
        checksum, size, kind = struct.unpack_from('<IHB', data, pos)
        if checksum == size == kind == 0:
            pos += remain
            continue
        if size + 7 > remain:
            raise ValueError('log fragment crosses physical block')
        end = pos + 7 + size
        if end > len(data):
            if allow_tail:
                return
            raise ValueError('incomplete log payload')
        payload = data[pos + 7:end]
        if masked_crc(bytes([kind]) + payload) != checksum:
            raise ValueError('log checksum mismatch')
        pos = end
        if kind == 1:
            if pending is not None:
                raise ValueError('unfinished fragmented record')
            yield payload
        elif kind == 2:
            if pending is not None:
                raise ValueError('nested fragmented record')
            pending = bytearray(payload)
        elif kind in (3, 4):
            if pending is None:
                raise ValueError('log fragment missing first part')
            pending.extend(payload)
            if len(pending) > MAX_BLOCK:
                raise ValueError('log record too large')
            if kind == 4:
                yield bytes(pending)
                pending = None
        else:
            raise ValueError(f'unsupported log type {kind}')
    if pending is not None and not allow_tail:
        raise ValueError('incomplete fragmented record')

def manifest_files(data):
    active, lognum, prevlog = set(), 0, 0
    for record in log_records(data):
        pos = 0
        while pos < len(record):
            tag, pos = varint(record, pos)
            if tag == 1:
                comparator, pos = field(record, pos)
                if comparator != b'leveldb.BytewiseComparator':
                    raise ValueError('unsupported database comparator')
            elif tag in (2, 3, 4, 9):
                value, pos = varint(record, pos)
                if tag == 2:
                    lognum = value
                elif tag == 9:
                    prevlog = value
            elif tag == 5:
                _, pos = varint(record, pos)
                _, pos = field(record, pos)
            elif tag in (6, 7):
                _, pos = varint(record, pos)
                number, pos = varint(record, pos)
                if tag == 6:
                    active.discard(number)
                else:
                    _, pos = varint(record, pos)
                    _, pos = field(record, pos)
                    _, pos = field(record, pos)
                    active.add(number)
            else:
                raise ValueError(f'unsupported manifest tag {tag}')
    return active, lognum, prevlog

def block_entries(block):
    if len(block) < 4:
        raise ValueError('short SST block')
    restarts = struct.unpack_from('<I', block, len(block) - 4)[0]
    limit = len(block) - 4 - 4 * restarts
    if restarts < 1 or limit < 0:
        raise ValueError('invalid SST restart array')
    pos, previous = 0, b''
    while pos < limit:
        shared, pos = varint(block, pos)
        size, pos = varint(block, pos)
        value_size, pos = varint(block, pos)
        if shared > len(previous) or pos + size + value_size > limit:
            raise ValueError('invalid SST prefix entry')
        key = previous[:shared] + block[pos:pos + size]
        pos += size
        value = block[pos:pos + value_size]
        pos += value_size
        previous = key
        yield key, value

def sst_entries(data):
    if len(data) < 48 or data[-8:] != bytes.fromhex('57fb808b247547db'):
        raise ValueError('unsupported SST footer; expected observed LevelDB legacy format')
    footer = data[-48:-8]
    _, pos = varint(footer)
    _, pos = varint(footer, pos)
    index_offset, pos = varint(footer, pos)
    index_size, _ = varint(footer, pos)
    def read_block(offset, size):
        if size > MAX_BLOCK or offset + size + 5 > len(data) - 48:
            raise ValueError('SST handle out of bounds')
        payload = data[offset:offset + size]
        kind = data[offset + size]
        crc = struct.unpack_from('<I', data, offset + size + 1)[0]
        if masked_crc(payload + bytes([kind])) != crc:
            raise ValueError('SST checksum mismatch')
        if kind == 0:
            return payload
        if kind == 1:
            return snappy(payload)
        raise ValueError(f'unsupported SST compression {kind}')
    for _, handle in block_entries(read_block(index_offset, index_size)):
        offset, pos = varint(handle)
        size, _ = varint(handle, pos)
        for key, value in block_entries(read_block(offset, size)):
            if len(key) < 8:
                raise ValueError('invalid internal key')
            packed = int.from_bytes(key[-8:], 'little')
            yield key[:-8], packed >> 8, packed & 255, value

def wal_entries(data):
    for record in log_records(data, allow_tail=True):
        if len(record) < 12:
            raise ValueError('short WriteBatch')
        sequence, count = struct.unpack_from('<QI', record)
        pos = 12
        for index in range(count):
            if pos >= len(record):
                raise ValueError('truncated WriteBatch')
            kind = record[pos]
            pos += 1
            if kind not in (0, 1):
                raise ValueError(f'unsupported WriteBatch type {kind}')
            key, pos = field(record, pos)
            value = b''
            if kind == 1:
                value, pos = field(record, pos)
            yield key, sequence + index, kind, value
        if pos != len(record):
            raise ValueError('extra WriteBatch bytes')

def read_database(directory, cache=None):
    """中文维护：按 CURRENT/MANIFEST 选活动文件并按 sequence 合并删除标记，绝不搜索废弃文件。"""
    current = (directory / 'CURRENT').read_bytes()
    manifest_name = current.decode('ascii').strip()
    if not re.fullmatch(r'MANIFEST-\d+', manifest_name):
        raise ValueError('invalid CURRENT manifest path')
    manifest = (directory / manifest_name).read_bytes()
    active, lognum, prevlog = manifest_files(manifest)
    latest = {}
    files = [(directory / f'{n:06d}.sst', sst_entries) for n in sorted(active)]
    files += [(f, wal_entries) for f in sorted(directory.glob('*.log'))
              if f.stem.isdigit() and (int(f.stem) >= lognum or int(f.stem) == prevlog)]
    if cache is not None:
        active_paths = {str(p) for p, _ in files}
        for path in list(cache):
            if path not in active_paths:
                del cache[path]
    for path, parser in files:
        stat = path.stat()
        if stat.st_size > 128 * 1024 * 1024:
            raise ValueError('database file exceeds read budget')
        # 中文维护：后台接收缓存未改变 SST 的 Suite 投影，只解析新 WAL/压缩后的新文件；
        # 游戏普通设置写入不应反复解压整库。缓存最多持有当前活动文件，文件身份变化即失效。
        identity = (stat.st_size, stat.st_mtime_ns)
        cached = cache.get(str(path)) if cache is not None else None
        if cached is not None and cached[0] == identity:
            entries = cached[1]
        else:
            entries = [(key, sequence, kind, value) for key, sequence, kind, value in parser(path.read_bytes())
                       if b'addon_replicatedsuite_' in key]
            if cache is not None:
                cache[str(path)] = (identity, entries)
        for key, sequence, kind, value in entries:
            if kind not in (0, 1):
                raise ValueError('unsupported internal value type')
            old = latest.get(key)
            if old is None or sequence > old[0]:
                latest[key] = (sequence, kind, value)
            elif sequence == old[0] and (kind, value) != old[1:]:
                raise ValueError('conflicting records at identical sequence')
    if (directory / 'CURRENT').read_bytes() != current or (directory / manifest_name).read_bytes() != manifest:
        raise ValueError('database compacted during capture; rerun export')
    return {key: row for key, row in latest.items() if row[1] == 1}

def export_scalar(text, name):
    found = re.findall(r'\bstr_' + name + r'\s+"?str_([^\s".]+)', text)
    if len(found) != 1:
        raise ValueError(f'missing or ambiguous export field: {name}')
    return found[0]


def decode_mailbox(text, records=None, key=None):
    """中文维护：Native 缩进文本只解析本工具拥有的 ASCII 字段；不解释或执行 Lua。"""
    def scalar(name):
        return export_scalar(text, name)
    protocol = scalar('protocol')
    if protocol == 'RS-DIAGNOSTIC-FILE-2':
        # 中文维护：每个 Native key 低于实机 16383 字节截断边界；清单只在所有页回读后写入。
        # 严格按本次清单校验页号/长度/局部和全文校验，半写与混合旧页均拒绝生成 txt。
        size, count = int(scalar('byte_count')), int(scalar('page_count'))
        if records is None or key is None or scalar('page_bytes') != '4096':
            raise ValueError('missing paged export records')
        if not 0 < size <= 1048576 or count != (size + 4095) // 4096:
            raise ValueError('invalid paged export size/count')
        parts = []
        for index in range(1, count + 1):
            row = records.get(key + f'_page_{index:04d}'.encode('ascii'))
            if row is None:
                raise ValueError(f'missing export page: {index}')
            page = row[2].decode('utf-8', errors='strict')
            if export_scalar(page, 'protocol') != protocol + '-PAGE' or export_scalar(page, 'page_index') != str(index):
                raise ValueError(f'invalid export page identity: {index}')
            if export_scalar(page, 'report_checksum') != scalar('checksum'):
                raise ValueError('export pages still being saved; no txt generated')
            length = min(4096, size - (index - 1) * 4096)
            chunks = (length + 1023) // 1024
            if export_scalar(page, 'byte_count') != str(length) or export_scalar(page, 'chunk_count') != str(chunks):
                raise ValueError(f'invalid export page size: {index}')
            found = re.findall(r'\bstr_c(\d{4})\s+"?str_([0-9A-F]+)', page)
            if len(found) != chunks or sorted(int(i) for i, _ in found) != list(range(1, chunks + 1)):
                raise ValueError(f'missing/duplicate export page chunks: {index}')
            piece = bytearray()
            for chunk, encoded in sorted(found):
                expected = min(1024, length - (int(chunk) - 1) * 1024)
                if len(encoded) != expected * 2:
                    raise ValueError(f'truncated export page chunk: {index}/{chunk}')
                piece.extend(bytes.fromhex(encoded))
            if f'{zlib.adler32(piece):08X}' != export_scalar(page, 'checksum'):
                raise ValueError(f'export page checksum mismatch: {index}')
            parts.append(piece)
        data = b''.join(parts)
        if len(data) != size or f'{zlib.adler32(data):08X}' != scalar('checksum'):
            raise ValueError('report length/checksum mismatch; no txt generated')
        data.decode('utf-8', errors='strict')
        identity = re.search(r'\bstr_report_id\s+"?str_([^\s"]+)', text)
        return data, identity.group(1).rstrip('.') if identity else 'report'
    if protocol != 'RS-DIAGNOSTIC-FILE-1':
        raise ValueError('unsupported diagnostic protocol')
    size, count = int(scalar('byte_count')), int(scalar('chunk_count'))
    if not 0 < size <= 1048576 or not 0 < count <= 1024 or count != (size + 1023) // 1024:
        raise ValueError('invalid export size/count')
    chunks = re.findall(r'\bstr_c(\d{4})\s+"?str_([0-9A-F]+)', text)
    if len(chunks) != count:
        raise ValueError('missing export chunks')
    rows = {}
    for index, encoded in chunks:
        number = int(index)
        if number in rows or not 1 <= number <= count or len(encoded) % 2 or len(encoded) > 2048:
            raise ValueError('duplicate/out-of-range export chunk')
        rows[number] = bytes.fromhex(encoded)
    for index in range(1, count):
        if len(rows[index]) != 1024:
            raise ValueError('short intermediate export chunk')
    data = b''.join(rows[index] for index in range(1, count + 1))
    if len(data) != size or f'{zlib.adler32(data):08X}' != scalar('checksum'):
        raise ValueError('report length/checksum mismatch; no txt generated')
    data.decode('utf-8', errors='strict')
    # 中文维护：report_id 可能含小数点；身份只供文件名，原文中的身份仍逐字保留。
    identity = re.search(r'\bstr_report_id\s+"?str_([^\s"]+)', text)
    return data, identity.group(1).rstrip('.') if identity else 'report'

def find_udf(game):
    candidates = [p for p in game.glob('USER*/udf') if (p / 'CURRENT').is_file()]
    if not candidates:
        raise ValueError('未找到当前游戏的 USER*/udf 存档目录；可用 --udf 指定')
    # 中文维护：仅选择最近有提交记录的账号库；新账号没有快照时不兜底输出旧账号报告。
    return max(candidates, key=lambda p: max(f.stat().st_mtime_ns for f in p.iterdir() if f.is_file()))

def save_report(udf, output=None, cache=None):
    records = read_database(udf, cache)
    matches = [(key, row) for key, row in records.items() if key.endswith(MAILBOX)]
    if len(matches) != 1:
        raise ValueError('当前账号尚无唯一完整诊断快照。请先在游戏诊断页点“导出文件”；若客户端尚未落盘，请稍后重试。')
    key, row = matches[0]
    data, identity = decode_mailbox(row[2].decode('utf-8', errors='strict'), records, key)
    receipt = str(udf.resolve()) + ':' + key.decode() + ':' + str(row[0]) + ':' + f'{zlib.adler32(data):08X}'
    folder = report_folder()
    state_path = folder / '.last-export.json'
    if output is None and state_path.is_file():
        # 中文维护：接收器索引损坏不应阻止新导出；旧 txt 也须仍与完整正文一致才可复用。
        try:
            previous = json.loads(state_path.read_text(encoding='utf-8'))
            existing = Path(previous.get('path', ''))
            if previous.get('receipt') == receipt and existing.is_file() and existing.read_bytes() == data:
                return existing
        except (OSError, ValueError, TypeError):
            pass
    safe_id = re.sub(r'[^A-Za-z0-9_.-]', '_', identity)[:48]
    target = output or folder / f'RS-{datetime.now():%Y%m%d-%H%M%S-%f}-{safe_id}.txt'
    target.parent.mkdir(parents=True, exist_ok=True)
    # 中文维护：只创建新文件，禁止覆盖已有报告；UTF-8 原始字节保留正文换行及完整校验。
    with target.open('xb') as stream:
        stream.write(data)
    if target.read_bytes() != data:
        raise ValueError('txt write verification failed')
    if output is None:
        state_path.write_text(json.dumps({'receipt': receipt, 'path': str(target)}, ensure_ascii=False), encoding='utf-8')
    print(f'已生成完整诊断报告：{target}\n字节数：{len(data)}；正文校验通过。', flush=True)
    return target

def watch(game, specified_udf=None):
    """中文维护：一次启动后自动接收显式导出。只在数据库文件发生变化后重新读，不持续扫描全文。"""
    folder = report_folder()
    folder.mkdir(parents=True, exist_ok=True)
    # 中文维护：仅锁接收器自己的文件，不碰客户端 LOCK；重复启动不产生第二个接收进程。
    # 中文维护：锁移到系统临时目录；报告目录是可清空的用户输出，不承担接收器生命周期。
    lock_id = hashlib.sha256(str(folder.resolve()).casefold().encode('utf-8')).hexdigest()[:24]
    lock = (Path(tempfile.gettempdir()) / ('RS-diagnostic-receiver-' + lock_id + '.lock')).open('a+b')
    if lock.tell() == 0:
        lock.write(b'0')
        lock.flush()
    lock.seek(0)
    import msvcrt
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        print('诊断自动接收器已在运行。', flush=True)
        return 0
    print(f'诊断自动接收器已启动。请保留此窗口。\n在游戏中点“导出文件”后，完整 txt 将保存到：{folder}', flush=True)
    stop_path = folder / '.stop-receiver'
    if stop_path.exists():
        stop_path.unlink()
    last_signature, last_error, cache, last_output = None, None, {}, None
    try:
        while True:
            if stop_path.exists():
                print('诊断自动接收器已停止。', flush=True)
                break
            try:
                udf = specified_udf or find_udf(game)
                signature = (str(udf), tuple(sorted((p.name, p.stat().st_size, p.stat().st_mtime_ns)
                             for p in udf.iterdir() if p.is_file() and (p.suffix in ('.sst', '.log') or p.name.startswith('MANIFEST') or p.name == 'CURRENT'))))
                # 中文维护：报告被清空时即使客户端没有新写入，也可重新提取同一完整快照。
                # 空闲时只检查一个已生成文件；不读全文、不重新解压未改变的库。
                if signature != last_signature or (last_output is not None and not last_output.is_file()):
                    # 中文维护：失败也记住已观察文件身份；等待真实写入再重读，避免空闲全库轮询。
                    last_signature = signature
                    last_output = save_report(udf, cache=cache)
                    last_signature, last_error = signature, None
            except (OSError, ValueError, UnicodeError) as error:
                # 中文维护：保存未落盘、并发压缩、暂时缺块只重试，不输出伪成功；同一原因不刷日志。
                message = str(error)
                if message != last_error:
                    print('等待完整导出快照：' + message, flush=True)
                    last_error = message
            time.sleep(2)
    finally:
        lock.close()

def main():
    parser = argparse.ArgumentParser(description='完整诊断快照 -> 校验后的 UTF-8 txt（不修改客户端存档）')
    parser.add_argument('--game', type=Path, default=addon_root().parent)
    parser.add_argument('--udf', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--watch', action='store_true', help='自动接收；游戏内每次点击导出后自动保存 txt')
    parser.add_argument('--stop', action='store_true', help='停止本工具的自动接收，不影响游戏或存档')
    args = parser.parse_args()
    if args.stop:
        folder = report_folder()
        folder.mkdir(parents=True, exist_ok=True)
        (folder / '.stop-receiver').write_text('stop', encoding='ascii')
        print('已请求停止诊断自动接收器。')
        return 0
    if args.watch:
        return watch(args.game, args.udf)
    udf = args.udf or find_udf(args.game)
    save_report(udf, args.output)
    return 0

if __name__ == '__main__':
    # 中文维护：便携 exe/命令行重定向均输出 UTF-8，不依赖玩家系统代码页与 Python 环境变量。
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    try:
        sys.exit(main())
    except (OSError, ValueError, UnicodeError) as error:
        print(f'导出未完成：{error}', file=sys.stderr)
        sys.exit(1)
