// MapKit DAT — Apple マップのデータ側: 周辺検索 / ジオコーディング / 逆ジオ / 経路。
// API キー不要(MapKit TOP と同じ)。
//
// **実測でわかった要点**: MKLocalSearch / MKDirections / CLGeocoder の完了ハンドラは
// **メインキューに来る**。要求もメインキューから出す(TD がメインランループを回す)。
// 単体CLIでメインスレッドをセマフォで塞ぐと全部タイムアウトする。
//
// 経路の points 出力は MapKit TOP のカメラをパスに沿って飛ばす用途を想定
// (DAT to CHOP → lat/lon をカメラへ)。
#import <Foundation/Foundation.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {

using Table = std::vector<std::vector<std::string>>;

static std::string fmt(double v, int prec = 7)
{
    char b[48];
    snprintf(b, sizeof b, "%.*f", prec, v);
    return b;
}

class MapKitDAT final : public DAT_CPlusPlusBase {
public:
    MapKitDAT(const OP_NodeInfo*)
        : myAlive(std::make_shared<std::atomic<bool>>(true))
    {
        myGeocoder = [[CLGeocoder alloc] init];
    }

    ~MapKitDAT() override { *myAlive = false; }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        const std::string mode = str(in, "Mode", "search");
        const std::string query = str(in, "Query", "");
        const double lat = in->getParDouble("Latitude");
        const double lon = in->getParDouble("Longitude");
        const double span = std::max(50.0, in->getParDouble("Span"));
        const double dlat = in->getParDouble("Destlatitude");
        const double dlon = in->getParDouble("Destlongitude");
        const std::string transport = str(in, "Transport", "walking");
        const std::string routeOut = str(in, "Routeoutput", "steps");
        const int maxResults = std::max(1, std::min(100, (int)in->getParInt("Maxresults")));

        char sig[512];
        snprintf(sig, sizeof sig, "%s|%s|%.7f|%.7f|%.1f|%.7f|%.7f|%s|%s|%d",
                 mode.c_str(), query.c_str(), lat, lon, span, dlat, dlon,
                 transport.c_str(), routeOut.c_str(), maxResults);
        const bool force = myRefresh.exchange(false);
        if ((mySig != sig || force) && !myBusy.exchange(true)) {
            mySig = sig;
            myRequests++;
            myStart = CFAbsoluteTimeGetCurrent();
            request(mode, query, lat, lon, span, dlat, dlon, transport, routeOut, maxResults);
        }

        Table t;
        {
            std::lock_guard<std::mutex> l(myMutex);
            t = myTable;
        }
        out->setOutputDataType(DAT_OutDataType::Table);
        if (t.empty()) { out->setTableSize(1, 1); out->setCellString(0, 0, "status"); return; }
        const int32_t cols = (int32_t)t[0].size();
        out->setTableSize((int32_t)t.size(), cols);
        for (int32_t r = 0; r < (int32_t)t.size(); r++)
            for (int32_t c = 0; c < cols && c < (int32_t)t[r].size(); c++)
                out->setCellString(r, c, t[r][c].c_str());
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "MapKit";
        {
            OP_StringParameter p("Mode");
            p.label = "Mode"; p.page = P; p.defaultValue = "search";
            const char* n[] = {"search", "geocode", "reverse", "route"};
            const char* l[] = {"Search Nearby", "Geocode (address to lat/lon)",
                               "Reverse Geocode (lat/lon to address)", "Route"};
            m->appendMenu(p, 4, n, l);
        }
        { OP_StringParameter p("Query"); p.label = "Query"; p.page = P;
          p.defaultValue = "coffee"; m->appendString(p); }
        addF(m, P, "Latitude",  "Latitude",  35.6595, -90, 90);
        addF(m, P, "Longitude", "Longitude", 139.7005, -180, 180);
        addF(m, P, "Span",      "Search Span (m)", 800, 50, 50000);
        addF(m, P, "Destlatitude",  "Dest Latitude",  35.6812, -90, 90);
        addF(m, P, "Destlongitude", "Dest Longitude", 139.7671, -180, 180);
        {
            OP_StringParameter p("Transport");
            p.label = "Transport"; p.page = P; p.defaultValue = "walking";
            const char* n[] = {"walking", "driving", "transit"};
            const char* l[] = {"Walking", "Driving", "Transit"};
            m->appendMenu(p, 3, n, l);
        }
        {
            OP_StringParameter p("Routeoutput");
            p.label = "Route Output"; p.page = P; p.defaultValue = "steps";
            const char* n[] = {"steps", "points"};
            const char* l[] = {"Steps", "Points (polyline)"};
            m->appendMenu(p, 2, n, l);
        }
        { OP_NumericParameter p("Maxresults"); p.label = "Max Results"; p.page = P;
          p.defaultValues[0] = 25; p.minSliders[0] = 1; p.maxSliders[0] = 100;
          p.minValues[0] = 1; p.maxValues[0] = 100; p.clampMins[0] = p.clampMaxes[0] = true;
          m->appendInt(p); }
        { OP_NumericParameter p("Refresh"); p.label = "Refresh"; p.page = P; m->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Refresh")) myRefresh = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[6] = {"executes", "requests", "busy", "valid", "rows", "request_ms"};
        float rows = 0;
        {
            std::lock_guard<std::mutex> l(myMutex);
            rows = myTable.size() > 1 ? (float)(myTable.size() - 1) : 0.f;
        }
        const float v[6] = {(float)myExec.load(), (float)myRequests.load(),
                            myBusy.load() ? 1.f : 0.f, myValid.load() ? 1.f : 0.f,
                            rows, myMs.load()};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarning.empty()) s->setString(myWarning.c_str());
    }

private:
    static std::string str(const OP_Inputs* in, const char* k, const char* d)
    {
        const char* v = in->getParString(k);
        return v && *v ? v : d;
    }
    static void addF(OP_ParameterManager* m, const char* pg, const char* n, const char* l,
                     double def, double lo, double hi)
    {
        OP_NumericParameter p(n);
        p.label = l; p.page = pg;
        p.defaultValues[0] = def;
        p.minSliders[0] = lo; p.maxSliders[0] = hi;
        p.minValues[0] = lo;  p.maxValues[0] = hi;
        p.clampMins[0] = p.clampMaxes[0] = true;
        m->appendFloat(p);
    }

    void finish(Table t, bool ok, std::string warn)
    {
        {
            std::lock_guard<std::mutex> l(myMutex);
            myTable = std::move(t);
            myWarning = std::move(warn);
        }
        myValid = ok;
        myMs = (float)((CFAbsoluteTimeGetCurrent() - myStart) * 1000.0);
        myBusy = false;
    }

    // **要求はメインキューから出す**(完了ハンドラがメインキューに来るため)
    void request(std::string mode, std::string query, double lat, double lon, double span,
                 double dlat, double dlon, std::string transport, std::string routeOut,
                 int maxResults)
    {
        auto alive = myAlive;
        auto* self = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!alive->load()) return;
            @try {
                if (mode == "search")       self->startSearch(query, lat, lon, span, maxResults);
                else if (mode == "geocode") self->startGeocode(query, maxResults);
                else if (mode == "reverse") self->startReverse(lat, lon);
                else                        self->startRoute(lat, lon, dlat, dlon,
                                                             transport, routeOut);
            } @catch (NSException* ex) {
                self->finish({}, false, ex.reason ? ex.reason.UTF8String : "MapKit exception");
            }
        });
    }

    void startSearch(std::string query, double lat, double lon, double span, int maxResults)
    {
        auto alive = myAlive;
        auto* self = this;
        MKLocalSearchRequest* rq = [[MKLocalSearchRequest alloc] init];
        rq.naturalLanguageQuery = [NSString stringWithUTF8String:query.c_str()];
        rq.region = MKCoordinateRegionMakeWithDistance(
            CLLocationCoordinate2DMake(lat, lon), span, span);
        CLLocation* center = [[CLLocation alloc] initWithLatitude:lat longitude:lon];
        MKLocalSearch* ls = [[MKLocalSearch alloc] initWithRequest:rq];
        [ls startWithCompletionHandler:^(MKLocalSearchResponse* rs, NSError* e) {
            if (!alive->load()) return;
            Table t;
            t.push_back({"name", "lat", "lon", "distance_m", "category", "address", "phone", "url"});
            for (MKMapItem* mi in rs.mapItems) {
                if ((int)t.size() > maxResults) break;
                const CLLocationCoordinate2D c = mi.placemark.coordinate;
                CLLocation* loc = [[CLLocation alloc] initWithLatitude:c.latitude
                                                             longitude:c.longitude];
                std::string cat = mi.pointOfInterestCategory ?
                    mi.pointOfInterestCategory.UTF8String : "";
                // "MKPOICategoryCafe" → "Cafe"
                if (cat.rfind("MKPOICategory", 0) == 0) cat = cat.substr(13);
                t.push_back({mi.name ? mi.name.UTF8String : "",
                             fmt(c.latitude), fmt(c.longitude),
                             fmt([loc distanceFromLocation:center], 0),
                             cat,
                             mi.placemark.title ? mi.placemark.title.UTF8String : "",
                             mi.phoneNumber ? mi.phoneNumber.UTF8String : "",
                             mi.url ? mi.url.absoluteString.UTF8String : ""});
            }
            self->finish(std::move(t), rs.mapItems.count > 0,
                         rs.mapItems.count ? "" :
                         (e ? (e.localizedDescription.UTF8String ?: "search failed")
                            : "No results"));
        }];
    }

    static Table placemarksToTable(NSArray<CLPlacemark*>* pms, int maxResults)
    {
        Table t;
        t.push_back({"name", "lat", "lon", "country", "admin_area", "locality",
                     "thoroughfare", "postal_code"});
        for (CLPlacemark* pm in pms) {
            if ((int)t.size() > maxResults) break;
            const CLLocationCoordinate2D c = pm.location.coordinate;
            t.push_back({pm.name ? pm.name.UTF8String : "",
                         fmt(c.latitude), fmt(c.longitude),
                         pm.country ? pm.country.UTF8String : "",
                         pm.administrativeArea ? pm.administrativeArea.UTF8String : "",
                         pm.locality ? pm.locality.UTF8String : "",
                         pm.thoroughfare ? pm.thoroughfare.UTF8String : "",
                         pm.postalCode ? pm.postalCode.UTF8String : ""});
        }
        return t;
    }

    // CLGeocoder は「東京駅」のような地名で kCLErrorDomain 8(結果なし)を返す(実測)。
    // MKLocalSearch を地域制約なしで使う方が地名・住所とも強い
    void startGeocode(std::string query, int maxResults)
    {
        auto alive = myAlive;
        auto* self = this;
        MKLocalSearchRequest* rq = [[MKLocalSearchRequest alloc] init];
        rq.naturalLanguageQuery = [NSString stringWithUTF8String:query.c_str()];
        MKLocalSearch* ls = [[MKLocalSearch alloc] initWithRequest:rq];
        [ls startWithCompletionHandler:^(MKLocalSearchResponse* rs, NSError* e) {
            if (!alive->load()) return;
            Table t;
            t.push_back({"name", "lat", "lon", "country", "admin_area", "locality",
                         "thoroughfare", "postal_code"});
            for (MKMapItem* mi in rs.mapItems) {
                if ((int)t.size() > maxResults) break;
                MKPlacemark* pm = mi.placemark;   // MKPlacemark は coordinate を直接持つ
                const CLLocationCoordinate2D c = pm.coordinate;
                t.push_back({mi.name ? mi.name.UTF8String : "",
                             fmt(c.latitude), fmt(c.longitude),
                             pm.country ? pm.country.UTF8String : "",
                             pm.administrativeArea ? pm.administrativeArea.UTF8String : "",
                             pm.locality ? pm.locality.UTF8String : "",
                             pm.thoroughfare ? pm.thoroughfare.UTF8String : "",
                             pm.postalCode ? pm.postalCode.UTF8String : ""});
            }
            self->finish(std::move(t), rs.mapItems.count > 0,
                         rs.mapItems.count ? "" :
                         (e ? (e.localizedDescription.UTF8String ?: "geocode failed")
                            : "No results"));
        }];
    }

    void startReverse(double lat, double lon)
    {
        auto alive = myAlive;
        auto* self = this;
        if (myGeocoder.geocoding) [myGeocoder cancelGeocode];
        CLLocation* loc = [[CLLocation alloc] initWithLatitude:lat longitude:lon];
        [myGeocoder reverseGeocodeLocation:loc
                         completionHandler:^(NSArray<CLPlacemark*>* pms, NSError* e) {
            if (!alive->load()) return;
            self->finish(placemarksToTable(pms, 10), pms.count > 0,
                         pms.count ? "" :
                         (e ? (e.localizedDescription.UTF8String ?: "reverse geocode failed")
                            : "No results"));
        }];
    }

    void startRoute(double lat, double lon, double dlat, double dlon,
                    std::string transport, std::string routeOut)
    {
        auto alive = myAlive;
        auto* self = this;
        MKDirectionsRequest* dr = [[MKDirectionsRequest alloc] init];
        dr.source = [[MKMapItem alloc] initWithPlacemark:
            [[MKPlacemark alloc] initWithCoordinate:CLLocationCoordinate2DMake(lat, lon)]];
        dr.destination = [[MKMapItem alloc] initWithPlacemark:
            [[MKPlacemark alloc] initWithCoordinate:CLLocationCoordinate2DMake(dlat, dlon)]];
        dr.transportType = (transport == "driving") ? MKDirectionsTransportTypeAutomobile
                         : (transport == "transit") ? MKDirectionsTransportTypeTransit
                                                    : MKDirectionsTransportTypeWalking;
        const bool points = (routeOut == "points");
        [[[MKDirections alloc] initWithRequest:dr] calculateDirectionsWithCompletionHandler:
            ^(MKDirectionsResponse* rs, NSError* e) {
            if (!alive->load()) return;
            if (!rs.routes.count) {
                self->finish({}, false,
                             e ? (e.localizedDescription.UTF8String ?: "no route") : "No route");
                return;
            }
            MKRoute* rt = rs.routes[0];
            Table t;
            if (points) {
                // カメラをパスに沿って飛ばす用途(DAT to CHOP → MapKit TOP の lat/lon へ)
                t.push_back({"index", "lat", "lon"});
                const NSUInteger n = rt.polyline.pointCount;
                std::vector<CLLocationCoordinate2D> cs(n);
                [rt.polyline getCoordinates:cs.data() range:NSMakeRange(0, n)];
                for (NSUInteger i = 0; i < n; i++)
                    t.push_back({std::to_string(i), fmt(cs[i].latitude), fmt(cs[i].longitude)});
            } else {
                t.push_back({"index", "instruction", "distance_m", "lat", "lon",
                             "total_distance_m", "total_minutes"});
                int idx = 0;
                for (MKRouteStep* st in rt.steps) {
                    const NSUInteger n = st.polyline.pointCount;
                    CLLocationCoordinate2D c = {0, 0};
                    if (n) [st.polyline getCoordinates:&c range:NSMakeRange(0, 1)];
                    t.push_back({std::to_string(idx++),
                                 st.instructions ? st.instructions.UTF8String : "",
                                 fmt(st.distance, 0), fmt(c.latitude), fmt(c.longitude),
                                 idx == 1 ? fmt(rt.distance, 0) : "",
                                 idx == 1 ? fmt(rt.expectedTravelTime / 60.0, 1) : ""});
                }
            }
            self->finish(std::move(t), true, "");
        }];
    }

    std::shared_ptr<std::atomic<bool>> myAlive;
    CLGeocoder* myGeocoder = nil;
    std::mutex myMutex;
    Table myTable;
    std::string mySig, myWarning;
    CFAbsoluteTime myStart = 0;
    std::atomic<uint64_t> myExec{0}, myRequests{0};
    std::atomic<bool> myBusy{false}, myValid{false}, myRefresh{false};
    std::atomic<float> myMs{0};
};

}  // namespace

extern "C" {

DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i)
{
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Mapkit");
    i->customOPInfo.opLabel->setString("MapKit");
    i->customOPInfo.opIcon->setString("MPK");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/MapKit/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i)
{
    return new MapKitDAT(i);
}

DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i)
{
    delete static_cast<MapKitDAT*>(i);
}

}
