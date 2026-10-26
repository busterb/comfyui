"""Split an API-format prompt into the part that runs locally and the part sent to the compute server.

Local: nodes that read the client's files (SOURCE_CLASSES) plus everything they depend on, and the output nodes
(save/preview) that exist on the client. Remote: whatever those output nodes need that isn't local. Values cross
over at two kinds of edges: a remote node reading a source's output gets a RemoteComputeValue stand-in, and a
local output node reading a remote node's output gets a RemoteComputePick fed by the RemoteComputeExecute node,
which runs the remote prompt. Node ids are kept, so progress and previews relayed from the server land on the
right nodes in the browser.
"""

import json

# Nodes that read files from the client's input/output folders. Their dependencies (index widgets fed by
# primitives, say) run locally too.
SOURCE_CLASSES = {
    "LoadImage", "LoadImageMask", "LoadImageOutput", "LoadImageFolderBatch", "LoadVideo", "LoadAudio",
    "LoadImageSetFromFolderNode", "LoadImageTextSetFromFolderNode",
}
# Output nodes that write no files: when their result also feeds nodes on the compute server (a text preview
# passing the text on), they run there as well as here (for the display).
FILE_FREE_OUTPUTS = {"PreviewAny"}
# Output nodes whose image inputs end up 8-bit: long frame batches may travel as uint8 for them.
EIGHT_BIT_SINKS = {"SaveImage", "PreviewImage", "SaveAnimatedWEBP", "SaveAnimatedPNG", "ImageCompare"}

EXEC_ID = "remote_compute_exec"


class SplitError(ValueError):
    pass


def _is_link(v):
    return isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and isinstance(v[1], int)


def _upstream(prompt, start, stop=frozenset()):
    """Node ids reachable backwards from `start`, not walking past (but including) `stop` nodes."""
    seen, todo = set(), list(start)
    while todo:
        nid = todo.pop()
        if nid in seen or nid not in prompt:
            continue
        seen.add(nid)
        if nid in stop:
            continue
        todo.extend(v[0] for v in prompt[nid].get("inputs", {}).values() if _is_link(v))
    return seen


def split(prompt, is_local_output, is_remote_output, targets=None):
    """Returns (local_prompt, spec) where spec describes the remote prompt, or (prompt, None) if all is local."""
    sources = {nid for nid, n in prompt.items() if n.get("class_type") in SOURCE_CLASSES}
    pre = _upstream(prompt, sources)
    sinks = {nid for nid, n in prompt.items() if nid not in pre and is_local_output(n.get("class_type"))}
    remote_outputs = {nid for nid, n in prompt.items()
                      if nid not in pre and nid not in sinks and is_remote_output(n.get("class_type"))}
    if targets is not None:
        targets = set(targets)
        sinks &= _upstream(prompt, targets & sinks)  # plus output nodes the targets read (save -> compare)
        remote_outputs &= targets

    # Values the local output nodes need from the remote side, deduplicated by (node, slot). An output node may
    # read another one (a save node passing its image on to a compare node): both run here.
    captures = {}
    for sid in sorted(sinks):
        for name, v in prompt[sid].get("inputs", {}).items():
            if _is_link(v) and v[0] not in pre and v[0] not in sinks:
                key = f"{v[0]}.{v[1]}"
                captures.setdefault(key, {"src": v, "eight_bit": prompt[sid]["class_type"] in EIGHT_BIT_SINKS})
                captures[key]["eight_bit"] &= prompt[sid]["class_type"] in EIGHT_BIT_SINKS
    if not captures and not remote_outputs:
        return prompt, None

    roots = {c["src"][0] for c in captures.values()} | remote_outputs
    remote_ids = _upstream(prompt, roots, stop=sources) - sources
    for nid in remote_ids:
        if nid in sinks and prompt[nid]["class_type"] not in FILE_FREE_OUTPUTS:  # a save node would write to its disk
            raise SplitError(f"node {nid} ({prompt[nid]['class_type']}) is a save/preview node whose result feeds nodes that "
                             f"run on the compute server; remote_compute keeps those nodes local, so this can't be split")

    # Remote prompt: stand-ins for source outputs, captures for what the local outputs need
    remote, inputs, value_ids = {}, [], {}
    for nid in sorted(remote_ids):
        node = json.loads(json.dumps(prompt[nid]))
        for name, v in node.get("inputs", {}).items():
            if _is_link(v) and v[0] in sources:
                ref = (v[0], v[1])
                if ref not in value_ids:
                    value_ids[ref] = f"rc_value_{len(inputs)}"
                    remote[value_ids[ref]] = {"class_type": "RemoteComputeValue", "inputs": {"fingerprint": f"@in_{len(inputs)}"},
                                              "_meta": {"title": f"value from {v[0]}"}}
                    inputs.append(list(ref))
                node["inputs"][name] = [value_ids[ref], 0]
        remote[nid] = node
    for i, (key, c) in enumerate(sorted(captures.items())):
        remote[f"rc_capture_{i}"] = {"class_type": "RemoteComputeCapture",
                                     "inputs": {"value": c["src"], "job": "@job", "key": key, "eight_bit": c["eight_bit"]}}

    # Local prompt: sources and their dependencies, the executor, one pick per capture, the output nodes
    local = {nid: json.loads(json.dumps(prompt[nid])) for nid in pre}
    local[EXEC_ID] = {"class_type": "RemoteComputeExecute", "inputs": {"spec": json.dumps({"prompt": remote, "inputs": inputs}),
                                                                       **{f"in_{i}": ref for i, ref in enumerate(inputs)}},
                      "_meta": {"title": "Run on compute server"}}
    pick_ids = {}
    for i, key in enumerate(sorted(captures)):
        pick_ids[key] = f"remote_compute_pick_{i}"
        local[pick_ids[key]] = {"class_type": "RemoteComputePick", "inputs": {"results": [EXEC_ID, 0], "key": key}}
    for sid in sinks:
        node = json.loads(json.dumps(prompt[sid]))
        for name, v in node.get("inputs", {}).items():
            if _is_link(v) and v[0] not in pre and v[0] not in sinks:
                node["inputs"][name] = [pick_ids[f"{v[0]}.{v[1]}"], 0]
        local[sid] = node
    if len(inputs) > 64:
        raise SplitError(f"{len(inputs)} local inputs feed the remote part; at most 64 are supported")
    return local, {"remote_ids": sorted(remote_ids), "captures": sorted(captures), "inputs": inputs}
