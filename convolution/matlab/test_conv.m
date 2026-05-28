% test_conv.m — Generate golden reference outputs for 1D complex convolution
% Matches MATLAB's built-in conv() for complex double-precision inputs.
% Outputs are saved as binary files for comparison with C and assembly.

clear; clc;

% Test case 1: Small deterministic input (easy to hand-verify)
fprintf('=== Test Case 1: Small Deterministic ===\n');
S1 = [1+2i, 3-1i, 0+4i];        % N=3
K1 = [0.5-0.5i, 1+0i];          % M=2
Y1 = conv(S1, K1);
fprintf('S = '); disp(S1);
fprintf('K = '); disp(K1);
fprintf('Y = conv(S,K) = '); disp(Y1);
fprintf('Expected length: %d, Got: %d\n\n', length(S1)+length(K1)-1, length(Y1));

% Save as binary (real/imag interleaved, double precision)
write_complex_bin('golden_small.bin', Y1);

% Test case 2: Medium random input
fprintf('=== Test Case 2: Medium Random (N=64, M=16) ===\n');
rng(42);  % Fixed seed for reproducibility
N2 = 64; M2 = 16;
S2 = randn(1, N2) + 1i*randn(1, N2);
K2 = randn(1, M2) + 1i*randn(1, M2);
Y2 = conv(S2, K2);
fprintf('S length=%d, K length=%d, Y length=%d\n', N2, M2, length(Y2));
fprintf('Y[0] = %+.6f %+.6fi\n', real(Y2(1)), imag(Y2(1)));
fprintf('Y[end] = %+.6f %+.6fi\n\n', real(Y2(end)), imag(Y2(end)));
write_complex_bin('golden_medium.bin', Y2);
write_complex_bin('input_S_medium.bin', S2);
write_complex_bin('input_K_medium.bin', K2);

% Test case 3: Larger random input
fprintf('=== Test Case 3: Large Random (N=256, M=64) ===\n');
rng(123);
N3 = 256; M3 = 64;
S3 = randn(1, N3) + 1i*randn(1, N3);
K3 = randn(1, M3) + 1i*randn(1, M3);
Y3 = conv(S3, K3);
fprintf('S length=%d, K length=%d, Y length=%d\n', N3, M3, length(Y3));
fprintf('Y[0] = %+.6f %+.6fi\n', real(Y3(1)), imag(Y3(1)));
fprintf('Y[100] = %+.6f %+.6fi\n\n', real(Y3(101)), imag(Y3(101)));
write_complex_bin('golden_large.bin', Y3);

% Test case 4: Emu8086-sized (small, for emulator verification)
fprintf('=== Test Case 4: Emu8086 Test (N=4, M=3) ===\n');
rng(99);
N4 = 4; M4 = 3;
S4 = randn(1, N4) + 1i*randn(1, N4);
K4 = randn(1, M4) + 1i*randn(1, M4);
Y4 = conv(S4, K4);
fprintf('S = '); disp(S4);
fprintf('K = '); disp(K4);
fprintf('Y = '); disp(Y4);
write_complex_bin('golden_emu.bin', Y4);
write_complex_bin('input_S_emu.bin', S4);
write_complex_bin('input_K_emu.bin', K4);

% Also save as single-precision for 8086 comparison
write_complex_bin_single('golden_emu_f32.bin', Y4);
write_complex_bin_single('input_S_emu_f32.bin', S4);
write_complex_bin_single('input_K_emu_f32.bin', K4);

fprintf('\n=== All golden files generated ===\n');

% --- Helper functions ---
function write_complex_bin(filename, data)
    % Write complex vector as interleaved [real, imag] double-precision
    interleaved = zeros(1, 2*length(data));
    interleaved(1:2:end) = real(data);
    interleaved(2:2:end) = imag(data);
    fid = fopen(filename, 'wb');
    fwrite(fid, interleaved, 'double');
    fclose(fid);
    fprintf('  Wrote %s (%d doubles = %d complex values)\n', ...
        filename, length(interleaved), length(data));
end

function write_complex_bin_single(filename, data)
    % Write complex vector as interleaved [real, imag] single-precision
    interleaved = zeros(1, 2*length(data), 'single');
    interleaved(1:2:end) = single(real(data));
    interleaved(2:2:end) = single(imag(data));
    fid = fopen(filename, 'wb');
    fwrite(fid, interleaved, 'single');
    fclose(fid);
    fprintf('  Wrote %s (%d singles = %d complex values)\n', ...
        filename, length(interleaved), length(data));
end
