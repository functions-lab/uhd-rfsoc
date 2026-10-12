import numpy as np


class Beamformer:
    """
    Beamformer for a Uniform Linear Array (ULA).

    Parameters
    ----------
    num_channels : int
        Number of transmitting elements (e.g., 4 for 4T1R).
    element_spacing : float
        Spacing between adjacent elements (in meters).
    carrier_freq : float
        Carrier frequency in Hz (default = 135e9 for 135 GHz).
    """

    def __init__(self, num_channels=4, element_spacing=1.07e-3, carrier_freq=135e9):
        self.num_channels = num_channels
        self.element_spacing = element_spacing
        self.carrier_freq = carrier_freq
        self.c = 3e8  # speed of light (m/s)
        self.steering_angle_deg = None  # Cached steering angle

    def compute_weights(self, steering_angle_deg):
        """
        Compute complex beamforming weights for each channel.

        Parameters
        ----------
        steering_angle_deg : float
            Steering angle in degrees (required).

        Returns
        -------
        weights : ndarray of complex
            Complex weights of shape (num_channels, ).
        """

        # Convert to radians
        theta = np.deg2rad(steering_angle_deg)

        # Compute wavelength
        lam = self.c / self.carrier_freq

        # Compute phase increment between elements
        k = 2 * np.pi / lam
        delta_phi = -k * self.element_spacing * np.sin(theta)

        # Compute complex weights
        indices = np.arange(self.num_channels)
        weights = np.exp(1j * indices * delta_phi)

        # Normalize to unit magnitude (optional)
        # weights /= np.abs(weights).max()

        return weights

    def compute_weights_fixed_point(self, steering_angle_deg, bits=16):
        """
        Compute beamforming weights in fixed-point representation.

        Parameters
        ----------
        steering_angle_deg : float
            Steering angle in degrees (required).
        bits : int
            Number of bits for fixed-point representation (default = 16).

        Returns
        -------
        weights_real : ndarray of int
            Real part of weights in fixed-point format.
        weights_imag : ndarray of int
            Imaginary part of weights in fixed-point format.
        """
        # Get floating-point weights
        weights_float = self.compute_weights(
            steering_angle_deg=steering_angle_deg)

        # Extract real and imaginary parts
        real_part = np.real(weights_float)
        imag_part = np.imag(weights_float)

        # Scale to fixed-point range
        # For signed 16-bit: range is -32768 to 32767
        max_val = 2**(bits - 1) - 1

        # Convert to fixed-point (round to nearest integer)
        weights_real = np.round(real_part * max_val).astype(np.int16)
        weights_imag = np.round(imag_part * max_val).astype(np.int16)

        return weights_real, weights_imag

    def set_angle(self, steering_angle_deg):
        """
        Set the steering angle for cached computation.

        Parameters
        ----------
        steering_angle_deg : float
            Steering angle in degrees.
        """
        self.steering_angle_deg = steering_angle_deg

    def get_angle(self):
        """
        Get the current cached steering angle.

        Returns
        -------
        float or None
            Current steering angle in degrees, or None if not set.
        """
        return self.steering_angle_deg

    def get_weights(self):
        """
        Get floating-point beamforming weights using the cached steering angle.

        Returns
        -------
        weights : ndarray of complex
            Complex beamforming weights.

        Raises
        ------
        ValueError
            If no angle has been set via set_angle().
        """
        if self.steering_angle_deg is None:
            raise ValueError(
                "No steering angle has been set. Use set_angle() first.")
        return self.compute_weights(steering_angle_deg=self.steering_angle_deg)

    def get_weights_fixpt(self, bits=16):
        """
        Get fixed-point beamforming weights using the cached steering angle.

        Parameters
        ----------
        bits : int
            Number of bits for fixed-point representation (default = 16).

        Returns
        -------
        weights_real : ndarray of int
            Real part of weights in fixed-point format.
        weights_imag : ndarray of int
            Imaginary part of weights in fixed-point format.

        Raises
        ------
        ValueError
            If no angle has been set via set_angle().
        """
        if self.steering_angle_deg is None:
            raise ValueError(
                "No steering angle has been set. Use set_angle() first.")
        return self.compute_weights_fixed_point(steering_angle_deg=self.steering_angle_deg, bits=bits)

    def __repr__(self):
        angle_str = f", angle={self.steering_angle_deg}°" if self.steering_angle_deg is not None else ""
        return f"Beamformer(num_channels={self.num_channels}, " \
               f"element_spacing={self.element_spacing*1e3:.2f}mm, " \
               f"f={self.carrier_freq/1e9} GHz{angle_str})"


def run_tests():
    """
    Run 9 test cases for the Beamformer class.
    Tests beam steering angles from -90° to 90° at 135 GHz carrier frequency.
    """
    print("="*70)
    print("Running Beamformer Test Cases")
    print("Carrier Frequency: 135 GHz | Element Spacing: 1.07 mm | Channels: 4")
    print("="*70)

    # Test angles from -90 to 90 degrees
    test_angles = [-90, -60, -45, -30, 0, 30, 45, 60, 90]
    num_channels = 4
    element_spacing = 1.07e-3
    carrier_freq = 135e9

    for i, angle in enumerate(test_angles, 1):
        print(f"\n[Test Case {i}] Steering angle: {angle:+4}°")
        print("-"*70)

        # Create beamformer instance
        bf = Beamformer(num_channels=num_channels,
                        element_spacing=element_spacing,
                        carrier_freq=carrier_freq)

        # Compute weights (floating-point) with explicit angle
        weights = bf.compute_weights(steering_angle_deg=angle)

        # Compute weights (16-bit fixed-point) with explicit angle
        weights_real_fp, weights_imag_fp = bf.compute_weights_fixed_point(
            steering_angle_deg=angle, bits=16)

        # Display configuration
        print(f"Configuration: {bf}")
        print(f"\nFloating-point weights:")
        print(f"  Complex: {weights}")
        print(f"  Magnitude: {np.abs(weights)}")
        print(f"  Phase (deg): {np.angle(weights, deg=True)}")
        print(f"\n16-bit Fixed-point weights:")
        print(f"  Real part (int16): {weights_real_fp}")
        print(f"  Imag part (int16): {weights_imag_fp}")
        print(
            f"  Hex Real: {['0x{:04X}'.format(int(w) & 0xFFFF) for w in weights_real_fp]}")
        print(
            f"  Hex Imag: {['0x{:04X}'.format(int(w) & 0xFFFF) for w in weights_imag_fp]}")

        # Verify normalization
        assert np.allclose(np.abs(weights).max(
        ), 1.0), f"Weights not properly normalized for angle {angle}°"

        # Special case: broadside (0 degrees) should have zero phase
        if angle == 0:
            print(f"Expected: All phases should be 0° for broadside")
            assert np.allclose(np.angle(weights), 0.0,
                               atol=1e-10), "Phases should be 0 for broadside"
        else:
            # For non-zero angles, verify uniform phase progression
            phases = np.angle(weights)
            if num_channels > 1:
                phase_diffs = np.diff(phases)
                # Account for phase wrapping
                phase_diffs = np.mod(phase_diffs + np.pi, 2*np.pi) - np.pi
                print(f"Expected: Uniform phase progression between elements")
                print(f"Phase increments (deg): {np.rad2deg(phase_diffs)}")
                assert np.allclose(phase_diffs, phase_diffs[0], atol=1e-8), \
                    f"Phase increments should be uniform for angle {angle}°"

        print(f"✓ Test Case {i} PASSED")

    print("\n" + "="*70)
    print(f"All {len(test_angles)} Test Cases PASSED! ✓")
    print("="*70)


if __name__ == "__main__":
    run_tests()
