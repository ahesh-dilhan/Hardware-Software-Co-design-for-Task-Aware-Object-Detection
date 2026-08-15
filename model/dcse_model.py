"""Dependency-free functional model for the current DCSE HLS kernel."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

SPATIAL3X3_RESERVED = 0
POINTWISE_PROJECTION = 1
IDENTITY_RESIDUAL = 2
MAX_CHANNELS = 256
OUTPUT_CHANNELS = 16


def _require_signed(value: int, bits: int, name: str) -> None:
    minimum = -(1 << (bits - 1))
    maximum = (1 << (bits - 1)) - 1
    if not minimum <= value <= maximum:
        raise ValueError(f"{name}={value} is outside signed INT{bits}")


@dataclass(frozen=True)
class LayerDescriptor:
    """Software view of one 64-bit accelerator descriptor."""

    output_channels: int
    input_channels: int
    kernel_size: int
    layer_type: int

    def validate_for_current_kernel(self) -> None:
        if self.output_channels != OUTPUT_CHANNELS:
            raise ValueError("the current kernel always produces 16 channels")
        if not 1 <= self.input_channels <= MAX_CHANNELS:
            raise ValueError("input_channels must be in [1, 256]")
        if self.layer_type not in (
            SPATIAL3X3_RESERVED,
            POINTWISE_PROJECTION,
            IDENTITY_RESIDUAL,
        ):
            raise ValueError("unknown layer_type")

    def pack(self) -> int:
        for field_name, value in (
            ("output_channels", self.output_channels),
            ("input_channels", self.input_channels),
            ("kernel_size", self.kernel_size),
            ("layer_type", self.layer_type),
        ):
            if not 0 <= value <= 0xFFFF:
                raise ValueError(f"{field_name} does not fit in 16 bits")
        return (
            (self.output_channels << 48)
            | (self.input_channels << 32)
            | (self.kernel_size << 16)
            | self.layer_type
        )

    @classmethod
    def unpack(cls, word: int) -> "LayerDescriptor":
        if not 0 <= word <= 0xFFFFFFFFFFFFFFFF:
            raise ValueError("descriptor does not fit in 64 bits")
        return cls(
            output_channels=(word >> 48) & 0xFFFF,
            input_channels=(word >> 32) & 0xFFFF,
            kernel_size=(word >> 16) & 0xFFFF,
            layer_type=word & 0xFFFF,
        )


def project_pixel(
    inputs: Sequence[int],
    weights: Sequence[Sequence[int]],
    biases: Sequence[int],
    *,
    residual: bool,
) -> list[int]:
    """Model one pixel of the implemented pointwise channel projection.

    ``weights[oc][ic]`` corresponds directly to the current HLS weight layout.
    Spatial neighbors are deliberately absent because the current kernel does
    not consume them.
    """

    input_channels = len(inputs)
    if not 1 <= input_channels <= MAX_CHANNELS:
        raise ValueError("input channel count must be in [1, 256]")
    if len(weights) != OUTPUT_CHANNELS or len(biases) != OUTPUT_CHANNELS:
        raise ValueError("exactly 16 weight rows and biases are required")

    for input_channel, value in enumerate(inputs):
        _require_signed(value, 8, f"inputs[{input_channel}]")

    outputs: list[int] = []
    for output_channel in range(OUTPUT_CHANNELS):
        if len(weights[output_channel]) != input_channels:
            raise ValueError("every weight row must match the input width")
        _require_signed(biases[output_channel], 16,
                        f"biases[{output_channel}]")
        accumulator = biases[output_channel]
        for input_channel, input_value in enumerate(inputs):
            weight = weights[output_channel][input_channel]
            _require_signed(
                weight, 8, f"weights[{output_channel}][{input_channel}]"
            )
            accumulator += input_value * weight
        if residual and output_channel < input_channels:
            accumulator += inputs[output_channel]
        _require_signed(accumulator, 32, f"outputs[{output_channel}]")
        outputs.append(accumulator)
    return outputs
