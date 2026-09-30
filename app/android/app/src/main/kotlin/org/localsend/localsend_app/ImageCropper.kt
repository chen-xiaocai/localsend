package org.localsend.localsend_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.media.ExifInterface
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Crops and rotates an image file without loading the whole image into memory.
 *
 * The crop rect is normalized (0..1) and refers to the upright image, i.e. with the
 * EXIF orientation applied, which is what Flutter displays. It is mapped back to the
 * raw (sensor) orientation so that [BitmapRegionDecoder] only decodes the selected
 * region; the EXIF orientation and the user rotation are applied afterwards.
 */
object ImageCropper {
    private const val MAX_PIXELS = 64_000_000L

    private val copiedExifTags = listOf(
        ExifInterface.TAG_DATETIME,
        ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
    )

    fun crop(
        sourcePath: String,
        left: Double,
        top: Double,
        right: Double,
        bottom: Double,
        quarterTurns: Int,
        quality: Int,
        outputDir: File,
    ): String {
        val sourceExif = ExifInterface(sourcePath)
        val orientation = sourceExif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(sourcePath, bounds)
        val rawWidth = bounds.outWidth
        val rawHeight = bounds.outHeight
        require(rawWidth > 0 && rawHeight > 0) { "Cannot decode image bounds: $sourcePath" }

        // Upright normalized corners -> raw normalized corners.
        val (x1, y1) = uprightToRaw(orientation, left, top)
        val (x2, y2) = uprightToRaw(orientation, right, bottom)
        val region = Rect(
            (min(x1, x2) * rawWidth).roundToInt().coerceIn(0, rawWidth - 1),
            (min(y1, y2) * rawHeight).roundToInt().coerceIn(0, rawHeight - 1),
            (max(x1, x2) * rawWidth).roundToInt().coerceIn(1, rawWidth),
            (max(y1, y2) * rawHeight).roundToInt().coerceIn(1, rawHeight),
        )
        if (region.right <= region.left) region.right = region.left + 1
        if (region.bottom <= region.top) region.bottom = region.top + 1

        var sampleSize = 1
        while (region.width().toLong() * region.height() / (sampleSize.toLong() * sampleSize) > MAX_PIXELS) {
            sampleSize *= 2
        }

        val decoder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            BitmapRegionDecoder.newInstance(sourcePath)
        } else {
            @Suppress("DEPRECATION")
            BitmapRegionDecoder.newInstance(sourcePath, false)
        } ?: throw IllegalStateException("Cannot open region decoder: $sourcePath")

        val regionBitmap = try {
            decoder.decodeRegion(region, BitmapFactory.Options().apply { inSampleSize = sampleSize })
        } finally {
            decoder.recycle()
        } ?: throw IllegalStateException("Cannot decode region $region of $sourcePath")

        val matrix = orientationMatrix(orientation)
        matrix.postRotate(90f * (quarterTurns % 4))
        val output = if (matrix.isIdentity) {
            regionBitmap
        } else {
            Bitmap.createBitmap(regionBitmap, 0, 0, regionBitmap.width, regionBitmap.height, matrix, true).also {
                if (it !== regionBitmap) {
                    regionBitmap.recycle()
                }
            }
        }

        val outputFile = File(outputDir, "crop_${UUID.randomUUID()}.jpg")
        try {
            FileOutputStream(outputFile).use { stream ->
                output.compress(Bitmap.CompressFormat.JPEG, quality, stream)
            }
        } finally {
            output.recycle()
        }

        copyExif(sourceExif, outputFile.path)
        return outputFile.path
    }

    /** Maps a normalized point of the upright image to the raw image, for each EXIF orientation. */
    private fun uprightToRaw(orientation: Int, x: Double, y: Double): Pair<Double, Double> {
        return when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> Pair(1 - x, y)
            ExifInterface.ORIENTATION_ROTATE_180 -> Pair(1 - x, 1 - y)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> Pair(x, 1 - y)
            ExifInterface.ORIENTATION_TRANSPOSE -> Pair(y, x)
            ExifInterface.ORIENTATION_ROTATE_90 -> Pair(y, 1 - x)
            ExifInterface.ORIENTATION_TRANSVERSE -> Pair(1 - y, 1 - x)
            ExifInterface.ORIENTATION_ROTATE_270 -> Pair(1 - y, x)
            else -> Pair(x, y)
        }
    }

    /** The transformation that turns the raw image into the upright image. */
    private fun orientationMatrix(orientation: Int): Matrix {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
        }
        return matrix
    }

    /** Keeps capture time, camera and location; the pixels are already upright. */
    private fun copyExif(source: ExifInterface, outputPath: String) {
        try {
            val target = ExifInterface(outputPath)
            for (tag in copiedExifTags) {
                source.getAttribute(tag)?.let { target.setAttribute(tag, it) }
            }
            target.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
            target.saveAttributes()
        } catch (e: Exception) {
            // Metadata is optional, the cropped image is still valid.
        }
    }
}
