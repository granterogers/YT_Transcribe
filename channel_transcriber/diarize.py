from __future__ import annotations

import numpy as np
from pathlib import Path


def embed_segments(audio_path: Path, segments: list[tuple[float, float, str]]) -> np.ndarray:
    """One voice-embedding per transcript segment, sliced directly from the audio."""
    from resemblyzer import VoiceEncoder, preprocess_wav
    wav = preprocess_wav(audio_path)
    encoder = VoiceEncoder()
    # preprocess_wav resamples to Resemblyzer's fixed 16kHz.
    sample_rate = 16000
    embeddings = []
    for start, end, _text in segments:
        clip = wav[int(start * sample_rate):int(end * sample_rate)]
        # Resemblyzer's encoder needs a minimum amount of audio to embed reliably.
        if len(clip) < sample_rate * 0.5:
            embeddings.append(None)
            continue
        embeddings.append(encoder.embed_utterance(clip))
    return embeddings


_SAME_SPEAKER_COSINE_DISTANCE = 0.25  # centroids closer than this are treated as one voice, not two


def cluster_speakers(embeddings: list[np.ndarray | None], max_speakers: int = 2) -> list[int]:
    """Group segment embeddings into up to `max_speakers` clusters; unlabeled segments inherit the previous speaker.

    Many videos on this channel are solo (Steve alone). Forcing a fixed cluster
    count would wrongly split a single voice, so clusters whose centroids are too
    close together (same-speaker distance) collapse back into one.
    """
    from sklearn.cluster import AgglomerativeClustering
    from sklearn.metrics.pairwise import cosine_distances
    valid_idx = [i for i, e in enumerate(embeddings) if e is not None]
    if len(valid_idx) < 2:
        return [0] * len(embeddings)
    matrix = np.stack([embeddings[i] for i in valid_idx])
    n_clusters = min(max_speakers, len(valid_idx))
    labels = AgglomerativeClustering(n_clusters=n_clusters, metric="cosine", linkage="average").fit_predict(matrix)
    if n_clusters > 1:
        centroids = np.stack([matrix[labels == c].mean(axis=0) for c in range(n_clusters)])
        if cosine_distances(centroids).max() < _SAME_SPEAKER_COSINE_DISTANCE:
            labels = np.zeros_like(labels)
    result = [None] * len(embeddings)
    for i, label in zip(valid_idx, labels):
        result[i] = int(label)
    last = 0
    for i in range(len(result)):
        if result[i] is None:
            result[i] = last
        else:
            last = result[i]
    return result


def label_speakers(cluster_ids: list[int]) -> list[str]:
    """Heuristic: the speaker of the first segment is Steve (channel host); everyone else is a Guest."""
    if not cluster_ids:
        return []
    steve_cluster = cluster_ids[0]
    others: dict[int, str] = {}
    labels = []
    for cid in cluster_ids:
        if cid == steve_cluster:
            labels.append("Steve")
            continue
        if cid not in others:
            others[cid] = "Guest" if not others else f"Guest {len(others) + 1}"
        labels.append(others[cid])
    return labels


def diarize_segments(audio_path: Path, segments: list[tuple[float, float, str]], max_speakers: int = 2) -> list[str]:
    """Full pipeline: audio + timed segments -> a speaker label ('Steve'/'Guest') per segment."""
    embeddings = embed_segments(audio_path, segments)
    cluster_ids = cluster_speakers(embeddings, max_speakers)
    return label_speakers(cluster_ids)
