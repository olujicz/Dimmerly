//
//  BridgingHeader.h
//  Dimmerly
//
//  Imports IOKit I2C headers for Intel DDC/CI support.
//  Swift's IOKit module does not expose <IOKit/i2c/IOI2CInterface.h>,
//  so we import it here to make IOI2CRequest, IOFBGetI2CInterfaceCount,
//  and related symbols available to DDCController on x86_64 builds.
//

#ifndef BridgingHeader_h
#define BridgingHeader_h

#include <IOKit/i2c/IOI2CInterface.h>

#endif /* BridgingHeader_h */
