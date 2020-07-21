#cython: language_level=3
#cython: boundscheck=False, wraparound=False, initializedcheck=False

from libc.string cimport memcpy
cimport cython

import numbers

import numpy as np
cimport numpy as cnp

from .base import EfficiencyWarning
from . cimport base

cnp.import_array()

cdef extern from *:
    void PyArray_ENABLEFLAGS(cnp.ndarray arr, int flags)
    void PyArray_CLEARFLAGS(cnp.ndarray arr, int flags)
    void *PyDataMem_NEW(size_t size)
    void *PyDataMem_NEW_ZEROED(size_t size, size_t elsize)
    void PyDataMem_FREE(void *ptr)


class OrderEfficiencyWarning(EfficiencyWarning):
    pass


cdef class Dense(base.Data):
    def __init__(self, data, shape=None, copy=True):
        base = np.array(data, dtype=np.complex128, order='K', copy=copy)
        if shape is None:
            shape = base.shape
            # Promote to a ket by default if passed 1D data.
            if len(shape) == 1:
                shape = (shape, 1)
        if not (
            len(shape) == 2
            and isinstance(shape[0], numbers.Integral)
            and isinstance(shape[1], numbers.Integral)
            and shape[0] > 0
            and shape[1] > 0
        ):
            raise ValueError("shape must be a 2-tuple of positive ints")
        if shape[0] * shape[1] != base.size:
            raise ValueError("".join([
                "invalid shape ",
                str(shape),
                " for input data with size ",
                str(base.size)
            ]))
        self._np = base.reshape(shape, order='A')
        self.data = <double complex *> cnp.PyArray_GETPTR2(self._np, 0, 0)
        self.fortran = cnp.PyArray_IS_F_CONTIGUOUS(self._np)
        self.shape = (base.shape[0], base.shape[1])

    def __repr__(self):
        return "".join([
            "Dense(shape=", str(self.shape), ", fortran=", str(self.fortran), ")",
        ])

    def __str__(self):
        return self.__repr__()

    cpdef Dense reorder(self, int fortran=-1):
        cdef bint fortran_
        if fortran < 0:
            fortran_ = not self.fortran
        else:
            fortran_ = fortran
        if bool(fortran_) == bool(self.fortran):
            return self.copy()
        cdef Dense out = empty_like(self, fortran_)
        cdef size_t idx_self=0, idx_out, stride, splits
        stride = self.shape[1] if self.fortran else self.shape[0]
        splits = self.shape[0] if self.fortran else self.shape[1]
        for idx_out in range(stride):
            for _ in range(splits):
                out.data[idx_out] = self.data[idx_self]
                idx_self += 1
                idx_out += stride
        return out

    cpdef Dense copy(self):
        """
        Return a complete (deep) copy of this object.

        If the type currently has a numpy backing, such as that produced by
        `as_ndarray`, this will not be copied.  The backing is a view onto our
        data, and a straight copy of this view would be incorrect.  We do not
        create a new view at copy time, since the user may only access this
        through a creation method, and creating it ahead of time would incur an
        unnecessary speed penalty for users who do not need it (including
        low-level C code).
        """
        cdef Dense out = Dense.__new__(Dense)
        cdef size_t size = self.shape[0]*self.shape[1]*sizeof(double complex)
        cdef double complex *ptr = <double complex *> PyDataMem_NEW(size)
        memcpy(ptr, self.data, size)
        out.shape = self.shape
        out.data = ptr
        out.fortran = self.fortran
        return out

    cdef void _fix_flags(self, object array):
        cdef int enable = cnp.NPY_ARRAY_OWNDATA
        cdef int disable = 0
        cdef cnp.Py_intptr_t *strides = cnp.PyArray_STRIDES(array)
        if self.shape[0] == 1 or self.shape[1] == 1:
            enable |= cnp.NPY_ARRAY_F_CONTIGUOUS | cnp.NPY_ARRAY_C_CONTIGUOUS
            strides[0] = self.shape[1] * sizeof(double complex)
            strides[1] = sizeof(double complex)
        elif self.fortran:
            enable |= cnp.NPY_ARRAY_F_CONTIGUOUS
            disable |= cnp.NPY_ARRAY_C_CONTIGUOUS
            strides[0] = sizeof(double complex)
            strides[1] = self.shape[0] * sizeof(double complex)
        else:
            enable |= cnp.NPY_ARRAY_C_CONTIGUOUS
            disable |= cnp.NPY_ARRAY_F_CONTIGUOUS
            strides[0] = self.shape[1] * sizeof(double complex)
            strides[1] = sizeof(double complex)
        PyArray_ENABLEFLAGS(array, enable)
        PyArray_CLEARFLAGS(array, disable)

    cpdef object to_array(self):
        """
        Get a copy of this data as a full 2D, contiguous NumPy array.  This may
        be Fortran or C-ordered, but will be contiguous in one of the
        dimensions.  This is not a view onto the data, and changes to new array
        will not affect the original data structure.
        """
        cdef size_t size = self.shape[0]*self.shape[1]*sizeof(double complex)
        cdef double complex *ptr = <double complex *> PyDataMem_NEW(size)
        memcpy(ptr, self.data, size)
        cdef object out =\
            cnp.PyArray_SimpleNewFromData(2, [self.shape[0], self.shape[1]],
                                          cnp.NPY_COMPLEX128, ptr)
        self._fix_flags(out)
        return out

    cpdef object as_ndarray(self):
        """
        Get a view onto this object as a `numpy.ndarray`.  The underlying data
        structure is exposed, such that modifications to the array will modify
        this object too.

        The array may be uninitialised, depending on how the Dense type was
        created.  The output will be contiguous and of dtype 'complex128', but
        may be C- or Fortran-ordered.
        """
        if self._np is not None:
            return self._np
        self._np =\
            cnp.PyArray_SimpleNewFromData(
                2, [self.shape[0], self.shape[1]], cnp.NPY_COMPLEX128, self.data
            )
        self._fix_flags(self._np)
        self._deallocate = False
        return self._np

    def __dealloc__(self):
        if self._deallocate and self.data != NULL:
            PyDataMem_FREE(self.data)


cpdef Dense empty(base.idxint rows, base.idxint cols, bint fortran=True):
    """
    Return a new Dense type of the given shape, with the data allocated but
    uninitialised.
    """
    cdef Dense out = Dense.__new__(Dense)
    out.shape = (rows, cols)
    out.data = <double complex *> PyDataMem_NEW(rows * cols * sizeof(double complex))
    out._deallocate = True
    out.fortran = fortran
    return out


cpdef Dense empty_like(Dense other, int fortran=-1):
    cdef bint fortran_
    if fortran < 0:
        fortran_ = other.fortran
    else:
        fortran_ = fortran
    return empty(other.shape[0], other.shape[1], fortran=fortran_)


cpdef Dense zeros(base.idxint rows, base.idxint cols, bint fortran=True):
    """Return the zero matrix with the given shape."""
    cdef Dense out = Dense.__new__(Dense)
    out.shape = (rows, cols)
    out.data =\
        <double complex *> PyDataMem_NEW_ZEROED(rows * cols, sizeof(double complex))
    out.fortran = fortran
    out._deallocate = True
    return out


cpdef Dense identity(base.idxint dimension, double complex scale=1,
                     bint fortran=True):
    """
    Return a square matrix of the specified dimension, with a constant along
    the diagonal.  By default this will be the identity matrix, but if `scale`
    is passed, then the result will be `scale` times the identity.
    """
    cdef size_t row
    cdef Dense out = zeros(dimension, dimension, fortran=fortran)
    for row in range(dimension):
        out.data[row*dimension + row] = scale
    return out
