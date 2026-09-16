"""Lossless captured-machine library for future bench fixtures; no dynamics inferred."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path

LIBRARY = Path(__file__).with_name('fixtures') / 'captured-vehicles'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def records(path):
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'rt', encoding='utf-8-sig') as stream:
        for line in stream:
            if line.strip():
                yield json.loads(line)


def import_captures(source, destination=LIBRARY):
    """Retain source bytes, every state and every observed attachment graph."""
    source, destination = Path(source), Path(destination)
    profiles, vehicles, combinations, payloads = {}, {}, {}, {}
    for path in sorted(source.glob('*.json')):
        raw = path.read_bytes()
        data = json.loads(raw.decode('utf-8-sig'))
        if data.get('schema') != 'fs25-geometry-capture' or data.get('schemaVersion') != 1:
            raise ValueError(f'Unsupported geometry schema: {path.name}')
        identity = data['identity']
        profile = {'file': 'profiles/' + path.name, 'sha256': digest(raw),
                   'capturedAt': data['capturedAt'], 'state': data['state'],
                   'labels': data.get('labels', {})}
        profiles[path.name] = (data, profile)
        vehicle = vehicles.setdefault(identity['id'], {'identity': identity, 'profiles': []})
        if vehicle['identity'] != identity:
            raise ValueError(f'Identity/configuration conflict: {identity["id"]}')
        vehicle['profiles'].append(profile)
        payloads[profile['file']] = raw
    if not profiles:
        raise ValueError('No geometry captures found')

    for path in sorted(source.glob('*.jsonl')):
        raw = path.read_bytes()
        lines = [json.loads(line) for line in raw.decode('utf-8-sig').splitlines() if line.strip()]
        header = lines[0]
        if header.get('schema') != 'fs25-geometry-motion' or header.get('schemaVersion') != 1:
            raise ValueError(f'Unsupported recording schema: {path.name}')
        members = header['members']
        instances = {m['instance'] for m in members}
        if len(instances) != len(members):
            raise ValueError(f'Duplicate machine instances: {path.name}')
        by_instance = {m['instance']: m for m in members}
        if sum(m['parentInstance'] is None for m in members) != 1:
            raise ValueError(f'Expected one root vehicle: {path.name}')
        links = []
        for member in members:
            profile_name = member['profileFile']
            if profile_name not in profiles:
                raise ValueError(f'Missing associated profile: {profile_name}')
            if profiles[profile_name][0]['identity'] != member['identity']:
                raise ValueError(f'Recording/profile identity mismatch: {profile_name}')
            seen, current = set(), member
            while current is not None:
                instance = current['instance']
                if instance in seen:
                    raise ValueError(f'Cyclic attachment graph: {path.name}')
                seen.add(instance)
                parent = current['parentInstance']
                if parent is not None and parent not in by_instance:
                    raise ValueError(f'Missing parent instance: {path.name}')
                current = by_instance.get(parent)
            links.append({'instance': member['instance'], 'vehicleId': member['identity']['id'],
                          'parentInstance': member['parentInstance'], 'jointIndex': member['jointIndex']})
        links.sort(key=lambda m: m['instance'])
        combination_id = digest(json.dumps(links, sort_keys=True).encode())[:16]
        combination = combinations.setdefault(combination_id, {
            'id': combination_id, 'name': ' + '.join(m['identity']['name'] for m in sorted(members, key=lambda m:m['instance'])),
            'members': links, 'recordings': []})
        samples = [line for line in lines[1:] if line.get('type') == 'sample']
        for sample in samples:
            sample_ids = [m['instance'] for m in sample['machines']]
            if len(sample_ids) != len(instances) or set(sample_ids) != instances:
                raise ValueError(f'Sample attachment membership changed: {path.name}')
        ending = lines[-1] if lines[-1].get('type') == 'end' else None
        if ending and ending['samples'] != len(samples):
            raise ValueError(f'Recording sample count mismatch: {path.name}')
        recording = {'file': 'recordings/' + path.name + '.gz', 'sourceSha256': digest(raw),
                     'samples': len(samples), 'complete': ending is not None,
                     'end': ending, 'members': members}
        combination['recordings'].append(recording)
        payloads[recording['file']] = gzip.compress(raw, mtime=0)

    for vehicle in vehicles.values():
        vehicle['profiles'].sort(key=lambda p: (p['capturedAt'], int(Path(p['file']).stem.rsplit('_', 1)[-1])))
        vehicle['defaultProfile'] = vehicle['profiles'][-1]['file']
    catalogue = {'schema': 'cp-bench-captured-geometry', 'schemaVersion': 1,
                 'units': {'length': 'metres', 'angle': 'radians'},
                 'limitations': [
                     'Profiles retain machine-root coordinates and captured direction vectors; root axes are not assumed to face forwards.',
                     'Declared dimensions and joint stops are not measured collision clearance.',
                     'Labels are user annotations, not geometry overrides or certified steering classification.',
                     'No field boundary, terrain physics or unobserved folded/working state is invented.',
                     'Full joint chains are retained. A simulator must explicitly support them before running a case.'
                 ],
                 'vehicles': sorted(vehicles.values(), key=lambda v:v['identity']['id']),
                 'combinations': sorted(combinations.values(), key=lambda c:c['name'])}
    # Validate everything before writing; imports never delete source captures.
    for name, raw in payloads.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'catalogue.json').write_text(json.dumps(catalogue, indent=2) + '\n', encoding='utf-8')
    return catalogue


def load_vehicle(vehicle_id, profile=None, library=LIBRARY):
    """Read a state-specific profile without normalising away pivots or offsets."""
    library = Path(library)
    vehicle = next(v for v in read_json(library / 'catalogue.json')['vehicles'] if v['identity']['id'] == vehicle_id)
    profile = profile or vehicle['defaultProfile']
    entry = next(p for p in vehicle['profiles'] if p['file'] == profile)
    raw = (library / entry['file']).read_bytes()
    if digest(raw) != entry['sha256']:
        raise ValueError('Captured profile checksum mismatch')
    return json.loads(raw.decode('utf-8-sig'))


def load_combination(combination_id, recording_index=-1, library=LIBRARY):
    """Return the observed graph, exact linked profiles and initial world poses."""
    library = Path(library)
    combination = next(c for c in read_json(library / 'catalogue.json')['combinations'] if c['id'] == combination_id)
    recording = combination['recordings'][recording_index]
    raw = gzip.decompress((library / recording['file']).read_bytes())
    if digest(raw) != recording['sourceSha256']:
        raise ValueError('Captured recording checksum mismatch')
    first = next((r for r in records(library / recording['file']) if r.get('type') == 'sample'), None)
    return {'name': combination['name'], 'members': [dict(m, geometry=load_vehicle(
        m['identity']['id'], 'profiles/' + m['profileFile'], library)) for m in recording['members']],
        'initialSample': first, 'recording': recording}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=LIBRARY)
    args = parser.parse_args()
    result = import_captures(args.source, args.output)
    print(f"Imported {len(result['vehicles'])} machines, "
          f"{sum(len(v['profiles']) for v in result['vehicles'])} profiles and "
          f"{len(result['combinations'])} combinations")
