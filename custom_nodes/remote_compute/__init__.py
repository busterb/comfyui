"""Run workflows on another machine's ComfyUI while every file stays on this one.

Install this pack on both machines. On the compute server (the GB10, say) it only adds in-memory routes and
two internal nodes: job inputs and results live in RAM and are dropped as soon as the client has them, along
with the job's history entry. On the client, set COMFYUI_REMOTE_URL (e.g. http://127.0.0.1:18188 through
`ssh -L 18188:127.0.0.1:8188 gb10`) and use the local web UI as usual: loaders and save/preview nodes run
locally, reading and writing the local input/ and output/ folders, and everything else runs on the server.
"""

import os

from . import server_side

NODE_CLASS_MAPPINGS = dict(server_side.NODE_CLASS_MAPPINGS)
NODE_DISPLAY_NAME_MAPPINGS = dict(server_side.NODE_DISPLAY_NAME_MAPPINGS)

if os.environ.get("COMFYUI_REMOTE_URL"):
    from . import client_side

    NODE_CLASS_MAPPINGS.update(client_side.NODE_CLASS_MAPPINGS)
    NODE_DISPLAY_NAME_MAPPINGS.update(client_side.NODE_DISPLAY_NAME_MAPPINGS)
