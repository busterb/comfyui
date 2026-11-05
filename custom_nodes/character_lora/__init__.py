"""Character LoRAs: apply up to two LoRAs (made with lora.sh) to a diffusion model, or none.

Unlike the core "LoraLoaderModelOnly" node, each slot can be "None", so a workflow with this node runs on a
machine that has no LoRAs at all. A slot set to None, or to strength 0, leaves the model unchanged.
"""

import folder_paths
import nodes

NONE = "None"


class CharacterLoRAs:
    def __init__(self):
        self.loaders = [nodes.LoraLoader(), nodes.LoraLoader()]  # each keeps its last LoRA file in memory

    @classmethod
    def INPUT_TYPES(cls):
        names = [NONE] + folder_paths.get_filename_list("loras")
        strength = ("FLOAT", {"default": 1.0, "min": -10.0, "max": 10.0, "step": 0.05})
        return {"required": {
            "model": ("MODEL",),
            "lora_1": (names, {"default": NONE, "tooltip": "A character LoRA (models/loras/characters/ from lora.sh). "
                                                           "Put its trigger word in the prompt."}),
            "strength_1": strength,
            "lora_2": (names, {"default": NONE, "tooltip": "A second character, for scenes with two."}),
            "strength_2": strength,
        }}

    RETURN_TYPES = ("MODEL",)
    FUNCTION = "apply"
    CATEGORY = "loaders"
    DESCRIPTION = "Apply up to two character LoRAs to the model. None leaves a slot empty."
    SEARCH_ALIASES = ["lora", "character lora", "puppet lora"]

    def apply(self, model, lora_1, strength_1, lora_2, strength_2):
        for loader, name, strength in zip(self.loaders, (lora_1, lora_2), (strength_1, strength_2)):
            if name != NONE and strength != 0:
                model = loader.load_lora(model, None, name, strength, 0)[0]
        return (model,)


NODE_CLASS_MAPPINGS = {"CharacterLoRAs": CharacterLoRAs}
NODE_DISPLAY_NAME_MAPPINGS = {"CharacterLoRAs": "Character LoRAs"}
