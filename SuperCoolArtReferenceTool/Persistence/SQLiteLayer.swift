import Foundation
import SQLite3
import simd

final class SQLiteLayer {
    private var db: OpaquePointer?

    init?(filename: String = "canvas.sqlite3") {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent(filename) else {
            return nil
        }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {}
        if sqlite3_open(url.path, &db) != SQLITE_OK { return nil }
        if !createSchema() { return nil }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func createSchema() -> Bool {
        let sql = """
        CREATE TABLE IF NOT EXISTS elements (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            transform0 REAL NOT NULL,
            transform1 REAL NOT NULL,
            transform2 REAL NOT NULL,
            transform3 REAL NOT NULL,
            transform4 REAL NOT NULL,
            transform5 REAL NOT NULL,
            transform6 REAL NOT NULL,
            transform7 REAL NOT NULL,
            transform8 REAL NOT NULL,
            bounds_x REAL NOT NULL,
            bounds_y REAL NOT NULL,
            bounds_w REAL NOT NULL,
            bounds_h REAL NOT NULL,
            layer_id TEXT NOT NULL,
            z_index INTEGER NOT NULL,
            image_url TEXT,
            image_w REAL,
            image_h REAL
        );
        """
        return exec(sql)
    }

    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<Int8>? = nil
        defer { if err != nil { sqlite3_free(err) } }
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            return false
        }
        return true
    }

    func upsertHeader(_ header: CMElementHeader, imageURL: URL? = nil, imageSize: SIMD2<Double>? = nil) {
        let sql = """
        INSERT INTO elements (id, type, transform0, transform1, transform2, transform3, transform4, transform5, transform6, transform7, transform8, bounds_x, bounds_y, bounds_w, bounds_h, layer_id, z_index, image_url, image_w, image_h)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            type=excluded.type,
            transform0=excluded.transform0,
            transform1=excluded.transform1,
            transform2=excluded.transform2,
            transform3=excluded.transform3,
            transform4=excluded.transform4,
            transform5=excluded.transform5,
            transform6=excluded.transform6,
            transform7=excluded.transform7,
            transform8=excluded.transform8,
            bounds_x=excluded.bounds_x,
            bounds_y=excluded.bounds_y,
            bounds_w=excluded.bounds_w,
            bounds_h=excluded.bounds_h,
            layer_id=excluded.layer_id,
            z_index=excluded.z_index,
            image_url=excluded.image_url,
            image_w=excluded.image_w,
            image_h=excluded.image_h;
        """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        func bindDouble(_ idx: Int32, _ value: Double) { sqlite3_bind_double(stmt, idx, value) }
        func bindText(_ idx: Int32, _ value: String) {
            // SQLITE_TRANSIENT is a C macro; define an equivalent here so SQLite copies the data immediately.
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?.self)
            value.withCString { cstr in
                _ = sqlite3_bind_text(stmt, idx, cstr, -1, SQLITE_TRANSIENT)
            }
        }
        func bindNull(_ idx: Int32) { sqlite3_bind_null(stmt, idx) }
        func bindInt(_ idx: Int32, _ value: Int32) { sqlite3_bind_int(stmt, idx, value) }

        // id, type
        bindText(1, header.id.uuidString)
        bindText(2, header.type.rawValue)

        // transform matrix (row-major)
        let m = header.transform.matrix
        bindDouble(3,  m.columns.0.x)
        bindDouble(4,  m.columns.0.y)
        bindDouble(5,  m.columns.0.z)
        bindDouble(6,  m.columns.1.x)
        bindDouble(7,  m.columns.1.y)
        bindDouble(8,  m.columns.1.z)
        bindDouble(9,  m.columns.2.x)
        bindDouble(10, m.columns.2.y)
        bindDouble(11, m.columns.2.z)

        // bounds
        bindDouble(12, header.bounds.origin.x)
        bindDouble(13, header.bounds.origin.y)
        bindDouble(14, header.bounds.size.x)
        bindDouble(15, header.bounds.size.y)

        // layer and zIndex
        bindText(16, header.layerId.uuidString)
        bindInt(17, Int32(header.zIndex))

        // image payload (optional)
        if let imageURL {
            bindText(18, imageURL.absoluteString)
        } else {
            bindNull(18)
        }
        if let imageSize {
            bindDouble(19, imageSize.x)
            bindDouble(20, imageSize.y)
        } else {
            bindNull(19)
            bindNull(20)
        }

        _ = sqlite3_step(stmt)
    }
}
