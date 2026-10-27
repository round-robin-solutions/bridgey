# Bridgey uses no reflection-based application models. Keep this file for
# release-specific rules as plugins are added.

# WorkManager (via Glance) creates its Room database reflectively. Keep generated
# database implementations and their no-argument constructors under R8 full mode.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
