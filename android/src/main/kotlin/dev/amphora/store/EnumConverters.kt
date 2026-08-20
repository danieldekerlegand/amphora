package dev.amphora.store

import androidx.room.TypeConverter
import dev.amphora.model.BlockReason
import dev.amphora.model.ErrorClass
import dev.amphora.model.PauseReason
import dev.amphora.model.SourceKind
import dev.amphora.model.UploadState

/** Room persists the state-machine enums by their stable names. */
class EnumConverters {
    @TypeConverter fun sourceKindToString(value: SourceKind?): String? = value?.name
    @TypeConverter fun stringToSourceKind(value: String?): SourceKind? = value?.let(SourceKind::valueOf)

    @TypeConverter fun uploadStateToString(value: UploadState?): String? = value?.name
    @TypeConverter fun stringToUploadState(value: String?): UploadState? = value?.let(UploadState::valueOf)

    @TypeConverter fun pauseReasonToString(value: PauseReason?): String? = value?.name
    @TypeConverter fun stringToPauseReason(value: String?): PauseReason? = value?.let(PauseReason::valueOf)

    @TypeConverter fun blockReasonToString(value: BlockReason?): String? = value?.name
    @TypeConverter fun stringToBlockReason(value: String?): BlockReason? = value?.let(BlockReason::valueOf)

    @TypeConverter fun errorClassToString(value: ErrorClass?): String? = value?.name
    @TypeConverter fun stringToErrorClass(value: String?): ErrorClass? = value?.let(ErrorClass::valueOf)
}
