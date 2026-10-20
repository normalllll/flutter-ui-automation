"""Preserve source pixels in FFV1/BGRA masters; MP4 files are viewing copies."""
import os
from pathlib import Path
import shutil
import subprocess


def inspect_video(path, region=None):
    """Decode a video and measure changes in the requested content region."""
    import json
    from runtime import run, program
    metadata = json.loads(run([program('ffprobe'), '-v', 'error', '-select_streams', 'v:0',
                               '-show_streams', '-show_format', '-of', 'json', path]).stdout)
    if not metadata.get('streams'):
        raise RuntimeError('Recording contains no video stream')
    stream = metadata['streams'][0]
    crop = 'crop={width}:{height}:{x}:{y},'.format(**region) if region else ''
    hashes = ffmpeg('-i', path, '-vf', crop + 'fps=2,scale=64:36',
                    '-pix_fmt', 'rgb24', '-f', 'framemd5', '-')
    frames = frame_hashes(hashes)
    if len(frames) < 2:
        raise RuntimeError('Recording cannot be decoded into multiple sample frames')
    return {'durationSeconds': float(metadata['format']['duration']),
            'width': stream['width'], 'height': stream['height'],
            'codec': stream['codec_name'], 'decodedSamples': len(frames),
            'uniqueSampleFrames': len(set(frames)), 'decodable': True}

NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def ffmpeg(*args, timeout=60):
    binary = shutil.which('ffmpeg')
    if not binary:
        raise RuntimeError('Missing FFmpeg')
    result = subprocess.run([binary, '-v', 'error', *map(str, args)],
        capture_output=True, text=True, timeout=timeout, creationflags=NO_WINDOW)
    if result.returncode:
        raise RuntimeError(f'FFmpeg failed: {result.stderr[-4000:]}')
    return result.stdout


def frame_hashes(text):
    return [line.split(',')[-1].strip() for line in text.splitlines()
            if line.strip() and not line.startswith('#')]


def media_timeout(frames):
    # Decoding and re-encoding scale with frame count; long 60 fps masters need more than a fixed minute.
    return 60 + frames * 0.1


def finalize_master(preview, source_hashes):
    preview = Path(preview)
    master = preview.with_suffix('.lossless.mkv')
    original = Path(source_hashes).read_text(encoding='utf-8')
    expected = frame_hashes(original)
    timeout = media_timeout(len(expected))
    decoded = ffmpeg('-i', master, '-c:v', 'rawvideo', '-pix_fmt', 'bgra', '-f', 'framemd5', '-',
                     timeout=timeout)
    actual = frame_hashes(decoded)
    source_dimensions = [line for line in original.splitlines() if line.startswith('#dimensions')]
    decoded_dimensions = [line for line in decoded.splitlines() if line.startswith('#dimensions')]
    if not expected or expected != actual or source_dimensions != decoded_dimensions:
        raise RuntimeError('Lossless master differs from original BGRA frames')
    width, height = map(int, source_dimensions[0].split(':')[-1].strip().split('x'))
    partial = preview.with_name(f'.{preview.stem}.partial{preview.suffix}')
    try:
        ffmpeg('-y', '-i', master, '-an', '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2',
               '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '18', '-pix_fmt',
               'yuv420p', '-movflags', '+faststart', '-f', 'mp4', partial, timeout=timeout)
        partial.replace(preview)
    finally:
        partial.unlink(missing_ok=True)
    return {'path': str(preview), 'previewIsLossy': True, 'masterPath': str(master),
            'masterCodec': 'ffv1', 'masterPixelFormat': 'bgra',
            'sourceFrameHashes': str(source_hashes), 'losslessVerified': True,
            'masterWidth': width, 'masterHeight': height,
            'verifiedFrames': len(actual)}


def encode_png_sequence(preview, frames, fps=5):
    preview, frames = Path(preview), Path(frames)
    master = preview.with_suffix('.lossless.mkv')
    source = preview.with_suffix('.source.framemd5')
    for stale in (preview, master, source):
        stale.unlink(missing_ok=True)
    count = len(list(frames.glob('*.png')))
    ffmpeg('-y', '-framerate', fps, '-i', frames/'%04d.png',
        '-map', '0:v:0', '-c:v', 'ffv1', '-level', '3', '-pix_fmt', 'bgra', master,
        '-map', '0:v:0', '-c:v', 'rawvideo', '-pix_fmt', 'bgra', '-f', 'framemd5', source,
        timeout=media_timeout(count))
    return {**finalize_master(preview, source), 'originalFramesDirectory': str(frames)}
