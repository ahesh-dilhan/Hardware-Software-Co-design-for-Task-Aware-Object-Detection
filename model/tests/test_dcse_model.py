import random
import unittest

from model.dcse_model import (
    IDENTITY_RESIDUAL,
    POINTWISE_PROJECTION,
    LayerDescriptor,
    project_pixel,
)


class DescriptorTests(unittest.TestCase):
    def test_pack_round_trip(self):
        descriptor = LayerDescriptor(16, 31, 1, IDENTITY_RESIDUAL)
        self.assertEqual(LayerDescriptor.unpack(descriptor.pack()), descriptor)
        descriptor.validate_for_current_kernel()

    def test_current_kernel_rejects_unsupported_output_width(self):
        with self.assertRaisesRegex(ValueError, "always produces 16"):
            LayerDescriptor(8, 16, 1,
                            POINTWISE_PROJECTION).validate_for_current_kernel()

    def test_current_kernel_rejects_too_many_inputs(self):
        with self.assertRaisesRegex(ValueError, r"\[1, 256\]"):
            LayerDescriptor(16, 257, 1,
                            POINTWISE_PROJECTION).validate_for_current_kernel()

    def test_current_kernel_rejects_unknown_layer_type(self):
        with self.assertRaisesRegex(ValueError, "unknown layer_type"):
            LayerDescriptor(16, 16, 1, 99).validate_for_current_kernel()

    def test_current_kernel_rejects_zero_inputs(self):
        with self.assertRaisesRegex(ValueError, r"\[1, 256\]"):
            LayerDescriptor(16, 0, 1,
                            POINTWISE_PROJECTION).validate_for_current_kernel()


class ProjectionTests(unittest.TestCase):
    def test_empty_input_vector_is_rejected(self):
        with self.assertRaisesRegex(ValueError, r"\[1, 256\]"):
            project_pixel([], [[] for _ in range(16)], [0] * 16,
                          residual=False)

    def test_known_dot_product_and_bias(self):
        inputs = [2, -3]
        weights = [[output_channel, 2] for output_channel in range(16)]
        biases = list(range(16))
        output = project_pixel(inputs, weights, biases, residual=False)
        self.assertEqual(output, [3 * output_channel - 6
                                  for output_channel in range(16)])

    def test_residual_is_zero_for_missing_identity_channels(self):
        inputs = [5]
        weights = [[0] for _ in range(16)]
        biases = [0] * 16
        output = project_pixel(inputs, weights, biases, residual=True)
        self.assertEqual(output[0], 5)
        self.assertEqual(output[1:], [0] * 15)

    def test_channel_boundaries_are_deterministic(self):
        random_source = random.Random(42)
        for input_channels in (1, 7, 16, 31, 256):
            with self.subTest(input_channels=input_channels):
                inputs = [random_source.randint(-128, 127)
                          for _ in range(input_channels)]
                weights = [
                    [random_source.randint(-128, 127)
                     for _ in range(input_channels)]
                    for _ in range(16)
                ]
                biases = [random_source.randint(-32768, 32767)
                          for _ in range(16)]
                plain = project_pixel(inputs, weights, biases, residual=False)
                residual = project_pixel(inputs, weights, biases, residual=True)
                for output_channel in range(16):
                    expected_delta = (
                        inputs[output_channel]
                        if output_channel < input_channels
                        else 0
                    )
                    self.assertEqual(
                        residual[output_channel] - plain[output_channel],
                        expected_delta,
                    )

    def test_int8_range_is_enforced(self):
        with self.assertRaisesRegex(ValueError, "signed INT8"):
            project_pixel([128], [[0] for _ in range(16)], [0] * 16,
                          residual=False)


if __name__ == "__main__":
    unittest.main()
